using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;

namespace ObitAutoAuth
{
    internal enum PortalOutcome
    {
        AlreadyOnline,
        AuthSuccess,
        ManualRequired,
        UnknownPortal,
        Offline,
        Error
    }

    internal sealed class PortalCheckResult
    {
        public PortalOutcome Outcome;
        public string PortalUrl = string.Empty;
        public string Message = string.Empty;
    }

    internal static class ObitPortalClient
    {
        public const string ProbeUrl = "http://connectivitycheck.gstatic.com/generate_204";

        private static readonly Regex MetaRefreshRegex = new Regex(
            @"<meta[^>]+http-equiv=[""']?refresh[""']?[^>]+content=[""']?\d+\s*;\s*url=([^""'>\s]+)",
            RegexOptions.IgnoreCase);
        private static readonly Regex JsLocationRegex = new Regex(
            @"(?:window\.location(?:\.href)?|location\.replace)\s*(?:=|\()\s*[""']([^""']+)[""']",
            RegexOptions.IgnoreCase);
        private static readonly Regex SessIdRegex = new Regex(@"OBIT_SessID=([a-zA-Z0-9_-]+)");
        private static readonly Regex ConnectBtnRegex = new Regex(
            @"id=[""']connect_btn[""'][^>]*onclick=(?:""[^""]*?(confirm\.php\?[^""'\s]+)|'[^']*?(confirm\.php\?[^""'\s]+))",
            RegexOptions.IgnoreCase);
        private static readonly Regex FormBlockRegex = new Regex(
            @"<form\b[^>]*action=[""']([^""']+)[""'][^>]*>([\s\S]*?)(?:</form>|$)",
            RegexOptions.IgnoreCase);
        private static readonly Regex FormMethodRegex = new Regex(
            @"method=[""']([^""']+)[""']",
            RegexOptions.IgnoreCase);
        private static readonly Regex InputTagRegex = new Regex(@"<input\b[^>]*>", RegexOptions.IgnoreCase);
        private static readonly Regex InputNameRegex = new Regex(@"\bname=[""']([^""']+)[""']", RegexOptions.IgnoreCase);
        private static readonly Regex InputValueRegex = new Regex(@"\bvalue=[""']([^""']*)[""']", RegexOptions.IgnoreCase);

        public static bool FastPathDefaultOnline()
        {
            try
            {
                IPAddress[] addrs = Dns.GetHostAddresses("connectivitycheck.gstatic.com");
                IPAddress ipv4 = null;
                for (int i = 0; i < addrs.Length; i++)
                {
                    if (addrs[i].AddressFamily == AddressFamily.InterNetwork)
                    {
                        ipv4 = addrs[i];
                        break;
                    }
                }
                if (ipv4 == null) return false;

                using (Socket sock = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp))
                {
                    sock.ReceiveTimeout = 2500;
                    sock.SendTimeout = 2500;
                    IAsyncResult ar = sock.BeginConnect(new IPEndPoint(ipv4, 80), null, null);
                    if (!ar.AsyncWaitHandle.WaitOne(2500, false)) return false;
                    sock.EndConnect(ar);

                    byte[] req = Encoding.ASCII.GetBytes(
                        "GET /generate_204 HTTP/1.1\r\nHost: connectivitycheck.gstatic.com\r\nConnection: close\r\n\r\n");
                    sock.Send(req);

                    byte[] buf = new byte[256];
                    int n = sock.Receive(buf);
                    if (n <= 0) return false;
                    string head = Encoding.ASCII.GetString(buf, 0, n);
                    return head.StartsWith("HTTP/1.1 204", StringComparison.Ordinal) ||
                           head.StartsWith("HTTP/1.0 204", StringComparison.Ordinal);
                }
            }
            catch
            {
                return false;
            }
        }

        private static HttpResponseData FollowHtmlRedirects(BypassHttpClient client, HttpResponseData resp)
        {
            for (int i = 0; i < 5; i++)
            {
                if (resp.StatusCode == 204) return resp;
                string nextTarget = null;
                Match meta = MetaRefreshRegex.Match(resp.Body);
                if (meta.Success)
                {
                    nextTarget = WebUtility.HtmlDecode(meta.Groups[1].Value);
                }
                else if (resp.FinalUrl.IndexOf("confirm.php", StringComparison.OrdinalIgnoreCase) < 0)
                {
                    Match js = JsLocationRegex.Match(resp.Body);
                    if (js.Success) nextTarget = WebUtility.HtmlDecode(js.Groups[1].Value);
                }
                if (string.IsNullOrEmpty(nextTarget)) break;
                string nextUrl = new Uri(new Uri(resp.FinalUrl), nextTarget).AbsoluteUri;
                if (nextUrl.Equals(resp.FinalUrl, StringComparison.OrdinalIgnoreCase)) break;
                resp = client.Request(nextUrl, "GET", null, resp.FinalUrl, true, 5000);
            }
            return resp;
        }

        private static void SubmitAutoFormIfPresent(BypassHttpClient client, HttpResponseData st3)
        {
            Match formMatch = FormBlockRegex.Match(st3.Body);
            if (!formMatch.Success) return;

            string action = WebUtility.HtmlDecode(formMatch.Groups[1].Value);
            if (string.IsNullOrEmpty(action)) return;
            string target = new Uri(new Uri(st3.FinalUrl), action).AbsoluteUri;
            Match methodMatch = FormMethodRegex.Match(formMatch.Value);
            string formMethod = methodMatch.Success ? methodMatch.Groups[1].Value.ToUpperInvariant() : "GET";
            string formInner = formMatch.Groups[2].Value;

            List<string> pairs = new List<string>();
            foreach (Match tag in InputTagRegex.Matches(formInner))
            {
                Match nameMatch = InputNameRegex.Match(tag.Value);
                if (!nameMatch.Success) continue;
                Match valMatch = InputValueRegex.Match(tag.Value);
                string val = valMatch.Success ? WebUtility.HtmlDecode(valMatch.Groups[1].Value) : string.Empty;
                pairs.Add(Uri.EscapeDataString(nameMatch.Groups[1].Value) + "=" + Uri.EscapeDataString(val));
            }

            string payload = string.Join("&", pairs.ToArray());
            if (formMethod == "POST")
            {
                client.Request(target, "POST", payload, st3.FinalUrl, true, 5000);
            }
            else if (!string.IsNullOrEmpty(payload))
            {
                string sep = target.Contains("?") ? "&" : "?";
                client.Request(target + sep + payload, "GET", null, st3.FinalUrl, true, 5000);
            }
            else
            {
                client.Request(target, "GET", null, st3.FinalUrl, true, 5000);
            }
        }

        public static PortalCheckResult CheckAndAuthorize(WifiAdapterInfo wifi)
        {
            PortalCheckResult result = new PortalCheckResult();
            BypassHttpClient client = new BypassHttpClient(wifi);

            try
            {
                HttpResponseData probe = client.Request(ProbeUrl, "GET", null, null, true, 5000);
                probe = FollowHtmlRedirects(client, probe);
                if (probe.StatusCode == 204)
                {
                    result.Outcome = PortalOutcome.AlreadyOnline;
                    result.Message = "Wi-Fi online";
                    return result;
                }

                string portalUrl = probe.FinalUrl;
                string body = probe.Body;
                result.PortalUrl = portalUrl;

                bool isObit = portalUrl.IndexOf("obit.ru", StringComparison.OrdinalIgnoreCase) >= 0 ||
                              portalUrl.IndexOf("OBIT_SessID", StringComparison.Ordinal) >= 0 ||
                              body.IndexOf("OBIT_SessID", StringComparison.Ordinal) >= 0;

                if (!isObit)
                {
                    result.Outcome = PortalOutcome.UnknownPortal;
                    result.Message = "Неизвестный captive-портал: " + portalUrl;
                    return result;
                }

                Match btnMatch = ConnectBtnRegex.Match(body);
                if (!btnMatch.Success)
                {
                    if (body.IndexOf("id=\"call_btn\"", StringComparison.OrdinalIgnoreCase) >= 0 ||
                        body.IndexOf("stage=stage2", StringComparison.OrdinalIgnoreCase) >= 0 ||
                        body.IndexOf("type=\"tel\"", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        result.Outcome = PortalOutcome.ManualRequired;
                        result.Message = "Портал ОБИТ требует подтверждение по телефону/SMS.";
                        return result;
                    }
                    result.Outcome = PortalOutcome.Error;
                    result.Message = "Не найдена кнопка Подключиться на странице портала.";
                    return result;
                }

                Match sessMatch = SessIdRegex.Match(portalUrl);
                if (!sessMatch.Success) sessMatch = SessIdRegex.Match(body);
                if (!sessMatch.Success)
                {
                    result.Outcome = PortalOutcome.Error;
                    result.Message = "Не найден OBIT_SessID.";
                    return result;
                }

                string sessId = sessMatch.Groups[1].Value;
                string stage3Rel = WebUtility.HtmlDecode(
                    btnMatch.Groups[1].Success ? btnMatch.Groups[1].Value : btnMatch.Groups[2].Value);

                Uri portalUri = new Uri(portalUrl);
                string ajxUrl = new Uri(portalUri,
                    "confirm.php?stage=ajx_check&OBIT_SessID=" + sessId + "&width=1920&height=1080").AbsoluteUri;
                string stage3Url = new Uri(portalUri, stage3Rel).AbsoluteUri;

                client.Request(ajxUrl, "GET", null, portalUrl, true, 5000, true);
                HttpResponseData st3 = client.Request(stage3Url, "GET", null, portalUrl, true, 5000);
                st3 = FollowHtmlRedirects(client, st3);

                if (st3.StatusCode != 204)
                {
                    SubmitAutoFormIfPresent(client, st3);
                }

                HttpResponseData verify = client.Request(ProbeUrl, "GET", null, null, true, 5000);
                if (verify.StatusCode == 204)
                {
                    result.Outcome = PortalOutcome.AuthSuccess;
                    result.Message = "Авторизация в ОБИТ успешно выполнена.";
                    return result;
                }

                result.Outcome = PortalOutcome.Error;
                result.Message = "После stage3 проверка вернула HTTP " + verify.StatusCode;
                return result;
            }
            catch (TimeoutException ex)
            {
                result.Outcome = PortalOutcome.Offline;
                result.Message = ex.Message;
                return result;
            }
            catch (SocketException ex)
            {
                result.Outcome = PortalOutcome.Offline;
                result.Message = ex.Message;
                return result;
            }
            catch (System.IO.IOException ex)
            {
                result.Outcome = PortalOutcome.Offline;
                result.Message = ex.Message;
                return result;
            }
            catch (Exception ex)
            {
                result.Outcome = PortalOutcome.Error;
                result.Message = ex.Message;
                return result;
            }
        }
    }
}
