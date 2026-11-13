// Test-only TLS server. No machine trust-store or production TLS policy changes.
using System;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Collections.Generic;
using System.Text;
using System.Threading;

namespace ArtemisOtaTlsFixture {
    public static class TestCertificates {
        private static readonly HashSet<string> Pins = new HashSet<string>();
        internal static void Register(string pin) { lock (Pins) { Pins.Add(pin); } }
        public static bool Validate(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
            lock (Pins) { return cert != null && Pins.Contains(cert.GetCertHashString()); }
        }
    }
    public sealed class RequestRecord {
        public string Path;
        public bool Authorization, Cookie, ProxyAuthorization;
    }
    public sealed class Reply {
        public int Status;
        public byte[] Body;
        public string ContentType, Location;
        public bool FragmentPrefix;
    }
    public sealed class Server : IDisposable {
        private readonly TcpListener listener;
        private readonly Thread thread;
        private readonly X509Certificate2 certificate;
        private readonly Dictionary<string, Queue<Reply>> routes = new Dictionary<string, Queue<Reply>>();
        private readonly List<RequestRecord> requests = new List<RequestRecord>();
        private volatile bool stopped;
        public string BaseUri { get; private set; }
        public RequestRecord[] Requests { get { lock (requests) { return requests.ToArray(); } } }
        public Server() {
            using (var key = RSA.Create(2048)) {
                var req = new CertificateRequest("CN=localhost", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                var san = new SubjectAlternativeNameBuilder();
                san.AddDnsName("localhost"); san.AddIpAddress(IPAddress.Loopback);
                req.CertificateExtensions.Add(san.Build());
                using (var cert = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddHours(2))) {
                    certificate = new X509Certificate2(cert.Export(X509ContentType.Pfx), "", X509KeyStorageFlags.DefaultKeySet);
                }
            }
            TestCertificates.Register(certificate.Thumbprint);
            listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
            BaseUri = "https://127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port + "/";
            thread = new Thread(Run); thread.IsBackground = true; thread.Start();
        }
        public void Add(string path, int status, byte[] body, string contentType, string location) {
            lock (routes) {
                Queue<Reply> q;
                if (!routes.TryGetValue(path, out q)) { q = new Queue<Reply>(); routes[path] = q; }
                q.Enqueue(new Reply { Status = status, Body = body ?? new byte[0], ContentType = contentType, Location = location });
            }
        }
        public void AddFragmented(string path, byte[] body) {
            lock (routes) {
                var q = new Queue<Reply>();
                q.Enqueue(new Reply { Status = 200, Body = body, ContentType = "application/octet-stream", FragmentPrefix = true });
                routes[path] = q;
            }
        }
        private void Run() {
            while (!stopped) {
                TcpClient client = null;
                try {
                    client = listener.AcceptTcpClient(); client.ReceiveTimeout = 4000; client.SendTimeout = 4000;
                    using (var stream = new SslStream(client.GetStream(), false)) {
                        stream.AuthenticateAsServer(certificate, false, SslProtocols.Tls12, false);
                        using (var reader = new StreamReader(stream, Encoding.ASCII, false, 8192, true)) {
                            string first = reader.ReadLine();
                            if (first == null) continue;
                            string[] parts = first.Split(' '); if (parts.Length != 3) continue;
                            var record = new RequestRecord { Path = parts[1] };
                            string line;
                            while (!String.IsNullOrEmpty(line = reader.ReadLine())) {
                                string h = line.Split(':')[0].ToLowerInvariant();
                                record.Authorization |= h == "authorization";
                                record.Cookie |= h == "cookie";
                                record.ProxyAuthorization |= h == "proxy-authorization";
                            }
                            lock (requests) { requests.Add(record); }
                            Reply reply = new Reply { Status = 404, Body = Encoding.UTF8.GetBytes("not found"), ContentType = "text/plain" };
                            lock (routes) {
                                Queue<Reply> q;
                                if (routes.TryGetValue(record.Path, out q)) reply = q.Count > 1 ? q.Dequeue() : q.Peek();
                            }
                            string headers = "HTTP/1.1 " + reply.Status + " Fixture\r\nContent-Length: " + reply.Body.Length + "\r\nConnection: close\r\n";
                            if (reply.ContentType != null) headers += "Content-Type: " + reply.ContentType + "\r\n";
                            if (reply.Location != null) headers += "Location: " + reply.Location + "\r\n";
                            // Deliberately attempt to establish a session; anonymous clients must ignore it.
                            headers += "Set-Cookie: fixture-session=must-not-forward; Path=/\r\n\r\n";
                            byte[] head = Encoding.ASCII.GetBytes(headers);
                            stream.Write(head, 0, head.Length);
                            if (reply.FragmentPrefix && reply.Body.Length > 1) {
                                stream.Write(reply.Body, 0, 1); stream.Flush(); Thread.Sleep(150);
                                stream.Write(reply.Body, 1, reply.Body.Length - 1);
                            } else stream.Write(reply.Body, 0, reply.Body.Length);
                            stream.Flush();
                        }
                    }
                } catch (Exception) { if (stopped) break; }
                finally { if (client != null) client.Close(); }
            }
        }
        public void Dispose() {
            stopped = true; listener.Stop(); thread.Join(4500); certificate.Dispose();
        }
    }
}
