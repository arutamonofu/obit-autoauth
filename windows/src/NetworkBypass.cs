using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Text;
using System.Threading;

namespace ObitAutoAuth
{
    internal sealed class WifiAdapterInfo
    {
        public string Name;
        public int InterfaceIndex;
        public IPAddress LocalIp;
        public IPAddress GatewayIp;
        public List<IPAddress> DnsServers;

        public static WifiAdapterInfo DetectActive()
        {
            NetworkInterface[] interfaces = NetworkInterface.GetAllNetworkInterfaces();
            for (int i = 0; i < interfaces.Length; i++)
            {
                NetworkInterface ni = interfaces[i];
                if (ni.OperationalStatus != OperationalStatus.Up) continue;
                if (ni.NetworkInterfaceType != NetworkInterfaceType.Wireless80211) continue;

                IPInterfaceProperties props = ni.GetIPProperties();
                IPv4InterfaceProperties ipv4Props = null;
                try { ipv4Props = props.GetIPv4Properties(); } catch { continue; }
                if (ipv4Props == null) continue;

                IPAddress localIp = null;
                foreach (UnicastIPAddressInformation uni in props.UnicastAddresses)
                {
                    if (uni.Address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(uni.Address))
                    {
                        localIp = uni.Address;
                        break;
                    }
                }
                if (localIp == null) continue;

                IPAddress gwIp = null;
                foreach (GatewayIPAddressInformation gw in props.GatewayAddresses)
                {
                    if (gw.Address.AddressFamily == AddressFamily.InterNetwork && !gw.Address.Equals(IPAddress.Any))
                    {
                        gwIp = gw.Address;
                        break;
                    }
                }
                if (gwIp == null) continue;

                List<IPAddress> dnsList = new List<IPAddress>();
                foreach (IPAddress dns in props.DnsAddresses)
                {
                    if (dns.AddressFamily == AddressFamily.InterNetwork)
                    {
                        dnsList.Add(dns);
                    }
                }
                if (dnsList.Count == 0)
                {
                    dnsList.Add(gwIp);
                }

                WifiAdapterInfo info = new WifiAdapterInfo();
                info.Name = ni.Name;
                info.InterfaceIndex = ipv4Props.Index;
                info.LocalIp = localIp;
                info.GatewayIp = gwIp;
                info.DnsServers = dnsList;
                return info;
            }
            return null;
        }
    }

    internal sealed class HttpResponseData
    {
        public int StatusCode;
        public string FinalUrl;
        public string Body;
        public Dictionary<string, string> Headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    }

    internal sealed class BypassHttpClient
    {
        private const int IP_UNICAST_IF = 31;
        private const string UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36";

        private static int _dnsSeq = Environment.TickCount;

        private readonly WifiAdapterInfo _wifi;
        private readonly Dictionary<string, string> _dnsCache = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, string> _cookies = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        public BypassHttpClient(WifiAdapterInfo wifi)
        {
            _wifi = wifi;
        }

        private static void ApplyUnicastIf(Socket sock, WifiAdapterInfo wifi)
        {
            try
            {
                int netOrderIndex = IPAddress.HostToNetworkOrder(wifi.InterfaceIndex);
                sock.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName)IP_UNICAST_IF, netOrderIndex);
            }
            catch
            {
                // Fallback to Bind() only if driver rejects IP_UNICAST_IF
            }
            sock.Bind(new IPEndPoint(wifi.LocalIp, 0));
        }

        private IPAddress ResolveHost(string host, int timeoutMs)
        {
            IPAddress parsed;
            if (IPAddress.TryParse(host, out parsed))
            {
                return parsed;
            }

            string cached;
            if (_dnsCache.TryGetValue(host, out cached))
            {
                return IPAddress.Parse(cached);
            }

            byte[] query = BuildDnsAQuery(host);
            ushort txId = (ushort)((query[0] << 8) | query[1]);

            for (int i = 0; i < _wifi.DnsServers.Count; i++)
            {
                IPAddress dnsServer = _wifi.DnsServers[i];
                try
                {
                    using (Socket udp = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp))
                    {
                        udp.ReceiveTimeout = timeoutMs;
                        udp.SendTimeout = timeoutMs;
                        ApplyUnicastIf(udp, _wifi);
                        udp.SendTo(query, new IPEndPoint(dnsServer, 53));

                        byte[] buf = new byte[2048];
                        int received = udp.Receive(buf);
                        IPAddress resolved = ParseDnsAResponse(buf, received, txId);
                        if (resolved != null)
                        {
                            _dnsCache[host] = resolved.ToString();
                            return resolved;
                        }
                    }
                }
                catch
                {
                    // Try next DNS server
                }
            }

            throw new IOException("DNS resolution failed via Wi-Fi DNS for " + host);
        }

        private static byte[] BuildDnsAQuery(string host)
        {
            ushort txId = (ushort)(Interlocked.Increment(ref _dnsSeq) & 0xFFFF);
            if (txId == 0) txId = 1;

            List<byte> pkt = new List<byte>();
            pkt.Add((byte)(txId >> 8));
            pkt.Add((byte)(txId & 0xFF));
            pkt.Add(0x01); pkt.Add(0x00); // Standard query, recursion desired
            pkt.Add(0x00); pkt.Add(0x01); // QDCOUNT = 1
            pkt.Add(0x00); pkt.Add(0x00); // ANCOUNT = 0
            pkt.Add(0x00); pkt.Add(0x00); // NSCOUNT = 0
            pkt.Add(0x00); pkt.Add(0x00); // ARCOUNT = 0

            string[] labels = host.Trim('.').Split('.');
            for (int i = 0; i < labels.Length; i++)
            {
                byte[] labelBytes = Encoding.ASCII.GetBytes(labels[i]);
                pkt.Add((byte)labelBytes.Length);
                pkt.AddRange(labelBytes);
            }
            pkt.Add(0x00);
            pkt.Add(0x00); pkt.Add(0x01); // QTYPE = A
            pkt.Add(0x00); pkt.Add(0x01); // QCLASS = IN
            return pkt.ToArray();
        }

        private static int SkipDnsName(byte[] buf, int len, int offset)
        {
            while (offset < len)
            {
                byte b = buf[offset];
                if (b == 0) return offset + 1;
                if ((b & 0xC0) == 0xC0) return offset + 2;
                offset += 1 + b;
            }
            return len;
        }

        private static IPAddress ParseDnsAResponse(byte[] buf, int len, ushort expectedTxId)
        {
            if (len < 12) return null;
            ushort txId = (ushort)((buf[0] << 8) | buf[1]);
            if (txId != expectedTxId) return null;
            if ((buf[3] & 0x0F) != 0) return null;

            int qdCount = (buf[4] << 8) | buf[5];
            int anCount = (buf[6] << 8) | buf[7];
            int offset = 12;

            for (int i = 0; i < qdCount; i++)
            {
                offset = SkipDnsName(buf, len, offset) + 4;
            }

            for (int i = 0; i < anCount && offset < len; i++)
            {
                offset = SkipDnsName(buf, len, offset);
                if (offset + 10 > len) break;
                int rtype = (buf[offset] << 8) | buf[offset + 1];
                int rclass = (buf[offset + 2] << 8) | buf[offset + 3];
                int rdLen = (buf[offset + 8] << 8) | buf[offset + 9];
                offset += 10;
                if (rtype == 1 && rclass == 1 && rdLen == 4 && offset + 4 <= len)
                {
                    byte[] ipBytes = new byte[4];
                    Array.Copy(buf, offset, ipBytes, 0, 4);
                    return new IPAddress(ipBytes);
                }
                offset += rdLen;
            }
            return null;
        }

        public HttpResponseData Request(
            string url,
            string method,
            string bodyData,
            string referer,
            bool followRedirects,
            int timeoutMs,
            bool isAjax = false)
        {
            string currentUrl = url;
            string currentMethod = method;
            string currentBody = bodyData;

            for (int hop = 0; hop < 8; hop++)
            {
                HttpResponseData resp = SendSingle(currentUrl, currentMethod, currentBody, referer, timeoutMs, isAjax);
                if (followRedirects && (resp.StatusCode == 301 || resp.StatusCode == 302 ||
                    resp.StatusCode == 303 || resp.StatusCode == 307 || resp.StatusCode == 308))
                {
                    string loc;
                    if (resp.Headers.TryGetValue("Location", out loc) && !string.IsNullOrEmpty(loc))
                    {
                        Uri nextUri = new Uri(new Uri(currentUrl), loc);
                        referer = currentUrl;
                        currentUrl = nextUri.AbsoluteUri;
                        if (resp.StatusCode == 303 ||
                            ((resp.StatusCode == 301 || resp.StatusCode == 302) && currentMethod == "POST"))
                        {
                            currentMethod = "GET";
                            currentBody = null;
                        }
                        isAjax = false;
                        continue;
                    }
                }
                return resp;
            }
            throw new IOException("Too many HTTP redirects");
        }

        private HttpResponseData SendSingle(
            string url,
            string method,
            string bodyData,
            string referer,
            int timeoutMs,
            bool isAjax)
        {
            Uri uri = new Uri(url);
            bool isHttps = uri.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase);
            int port = uri.IsDefaultPort ? (isHttps ? 443 : 80) : uri.Port;
            IPAddress targetIp = ResolveHost(uri.Host, timeoutMs);

            using (Socket sock = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp))
            {
                sock.ReceiveTimeout = timeoutMs;
                sock.SendTimeout = timeoutMs;
                ApplyUnicastIf(sock, _wifi);

                IAsyncResult ar = sock.BeginConnect(new IPEndPoint(targetIp, port), null, null);
                if (!ar.AsyncWaitHandle.WaitOne(timeoutMs, false))
                {
                    sock.Close();
                    throw new TimeoutException("TCP connect timed out: " + uri.Host);
                }
                sock.EndConnect(ar);

                using (NetworkStream netStream = new NetworkStream(sock, false))
                {
                    Stream stream = netStream;
                    SslStream ssl = null;
                    if (isHttps)
                    {
                        ssl = new SslStream(netStream, false);
                        ssl.AuthenticateAsClient(uri.Host, null, SslProtocols.Tls12, false);
                        stream = ssl;
                    }

                    try
                    {
                        StringBuilder req = new StringBuilder();
                        req.AppendFormat("{0} {1} HTTP/1.1\r\n", method, uri.PathAndQuery);
                        string hostHeader = uri.IsDefaultPort ? uri.Host : (uri.Host + ":" + port);
                        req.AppendFormat("Host: {0}\r\n", hostHeader);
                        req.AppendFormat("User-Agent: {0}\r\n", UserAgent);
                        req.Append("Accept: text/html,application/xhtml+xml,*/*;q=0.8\r\n");
                        req.Append("Connection: close\r\n");
                        if (!string.IsNullOrEmpty(referer))
                        {
                            req.AppendFormat("Referer: {0}\r\n", referer);
                        }
                        if (isAjax)
                        {
                            req.Append("X-Requested-With: XMLHttpRequest\r\n");
                        }
                        string cookieHeader = BuildCookieHeader();
                        if (!string.IsNullOrEmpty(cookieHeader))
                        {
                            req.AppendFormat("Cookie: {0}\r\n", cookieHeader);
                        }

                        byte[] bodyBytes = null;
                        if (!string.IsNullOrEmpty(bodyData))
                        {
                            bodyBytes = Encoding.UTF8.GetBytes(bodyData);
                            req.Append("Content-Type: application/x-www-form-urlencoded\r\n");
                            req.AppendFormat("Content-Length: {0}\r\n", bodyBytes.Length);
                        }
                        req.Append("\r\n");

                        byte[] headerBytes = Encoding.ASCII.GetBytes(req.ToString());
                        stream.Write(headerBytes, 0, headerBytes.Length);
                        if (bodyBytes != null)
                        {
                            stream.Write(bodyBytes, 0, bodyBytes.Length);
                        }
                        stream.Flush();

                        return ReadHttpResponse(stream, url);
                    }
                    finally
                    {
                        if (ssl != null) ssl.Dispose();
                    }
                }
            }
        }

        private string BuildCookieHeader()
        {
            if (_cookies.Count == 0) return string.Empty;
            List<string> pairs = new List<string>();
            foreach (KeyValuePair<string, string> kv in _cookies)
            {
                pairs.Add(kv.Key + "=" + kv.Value);
            }
            return string.Join("; ", pairs.ToArray());
        }

        private HttpResponseData ReadHttpResponse(Stream stream, string requestUrl)
        {
            MemoryStream raw = new MemoryStream();
            byte[] buf = new byte[8192];
            int headerEnd = -1;
            int totalRead = 0;

            while (true)
            {
                int n = stream.Read(buf, 0, buf.Length);
                if (n <= 0) break;
                raw.Write(buf, 0, n);
                totalRead += n;
                if (headerEnd < 0)
                {
                    headerEnd = FindHeaderEnd(raw.GetBuffer(), totalRead);
                    if (headerEnd >= 0) break;
                }
                if (totalRead > 64 * 1024) break;
            }

            if (headerEnd < 0)
            {
                throw new IOException("Malformed HTTP response from " + requestUrl);
            }

            byte[] initialBytes = raw.ToArray();
            string headerText = Encoding.ASCII.GetString(initialBytes, 0, headerEnd);
            string[] lines = headerText.Split(new string[] { "\r\n" }, StringSplitOptions.None);
            if (lines.Length == 0) throw new IOException("Empty HTTP status line");

            string[] statusParts = lines[0].Split(' ');
            int statusCode = 0;
            if (statusParts.Length >= 2) int.TryParse(statusParts[1], out statusCode);

            HttpResponseData data = new HttpResponseData();
            data.StatusCode = statusCode;
            data.FinalUrl = requestUrl;

            for (int i = 1; i < lines.Length; i++)
            {
                int colon = lines[i].IndexOf(':');
                if (colon <= 0) continue;
                string name = lines[i].Substring(0, colon).Trim();
                string val = lines[i].Substring(colon + 1).Trim();
                if (name.Equals("Set-Cookie", StringComparison.OrdinalIgnoreCase))
                {
                    int semi = val.IndexOf(';');
                    string pair = semi >= 0 ? val.Substring(0, semi) : val;
                    int eq = pair.IndexOf('=');
                    if (eq > 0)
                    {
                        _cookies[pair.Substring(0, eq).Trim()] = pair.Substring(eq + 1).Trim();
                    }
                }
                else
                {
                    data.Headers[name] = val;
                }
            }

            MemoryStream bodyStream = new MemoryStream();
            int leftover = initialBytes.Length - (headerEnd + 4);
            if (leftover > 0)
            {
                bodyStream.Write(initialBytes, headerEnd + 4, leftover);
            }

            string contentLengthStr;
            int contentLength = -1;
            if (data.Headers.TryGetValue("Content-Length", out contentLengthStr))
            {
                int.TryParse(contentLengthStr, out contentLength);
            }

            string te;
            bool isChunked = data.Headers.TryGetValue("Transfer-Encoding", out te) &&
                te.IndexOf("chunked", StringComparison.OrdinalIgnoreCase) >= 0;

            byte[] decodedChunked = null;
            if (statusCode != 204 && statusCode != 304 && contentLength != 0)
            {
                if (isChunked && TryDecodeChunked(bodyStream.ToArray(), out decodedChunked))
                {
                    data.Body = Encoding.UTF8.GetString(decodedChunked);
                    return data;
                }

                while (contentLength < 0 || bodyStream.Length < contentLength)
                {
                    int n = stream.Read(buf, 0, buf.Length);
                    if (n <= 0) break;
                    bodyStream.Write(buf, 0, n);
                    if (isChunked && TryDecodeChunked(bodyStream.ToArray(), out decodedChunked))
                    {
                        data.Body = Encoding.UTF8.GetString(decodedChunked);
                        return data;
                    }
                    if (bodyStream.Length > 512 * 1024) break;
                }
            }

            byte[] bodyBytes = bodyStream.ToArray();
            if (isChunked)
            {
                byte[] partial;
                TryDecodeChunked(bodyBytes, out partial);
                bodyBytes = partial;
            }

            data.Body = Encoding.UTF8.GetString(bodyBytes);
            return data;
        }

        private static int FindHeaderEnd(byte[] buf, int len)
        {
            for (int i = 0; i <= len - 4; i++)
            {
                if (buf[i] == 13 && buf[i + 1] == 10 && buf[i + 2] == 13 && buf[i + 3] == 10)
                {
                    return i;
                }
            }
            return -1;
        }

        private static bool TryDecodeChunked(byte[] input, out byte[] decoded)
        {
            MemoryStream output = new MemoryStream();
            int pos = 0;
            while (pos < input.Length)
            {
                int lineEnd = -1;
                for (int i = pos; i <= input.Length - 2; i++)
                {
                    if (input[i] == 13 && input[i + 1] == 10)
                    {
                        lineEnd = i;
                        break;
                    }
                }
                if (lineEnd < 0)
                {
                    decoded = output.ToArray();
                    return false;
                }

                string sizeLine = Encoding.ASCII.GetString(input, pos, lineEnd - pos);
                int semi = sizeLine.IndexOf(';');
                if (semi >= 0) sizeLine = sizeLine.Substring(0, semi);
                int chunkSize;
                if (!int.TryParse(sizeLine.Trim(), System.Globalization.NumberStyles.HexNumber, null, out chunkSize) || chunkSize < 0)
                {
                    decoded = output.ToArray();
                    return false;
                }
                if (chunkSize == 0)
                {
                    decoded = output.ToArray();
                    return input.Length >= lineEnd + 4;
                }

                pos = lineEnd + 2;
                if (pos + chunkSize + 2 > input.Length)
                {
                    decoded = output.ToArray();
                    return false;
                }
                output.Write(input, pos, chunkSize);
                pos += chunkSize + 2;
            }
            decoded = output.ToArray();
            return false;
        }
    }
}
