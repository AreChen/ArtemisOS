// Test-only dynamic OpenList API and anonymous CDN, using pinned ephemeral TLS.
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
using System.Text.RegularExpressions;
using System.Threading;

namespace ArtemisPublishTlsFixture {
    public static class Certificates {
        static readonly HashSet<string> pins = new HashSet<string>();
        internal static void Register(string pin) { lock(pins) pins.Add(pin); }
        public static bool Validate(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
            lock(pins) return cert != null && pins.Contains(cert.GetCertHashString());
        }
    }
    public sealed class Record {
        public string Method, Path, FilePath;
        public bool Authorization, Cookie, ProxyAuthorization;
    }
    public sealed class Server : IDisposable {
        readonly TcpListener listener;
        readonly Thread thread;
        readonly X509Certificate2 certificate;
        readonly List<Record> records = new List<Record>();
        readonly Dictionary<string,int> reads = new Dictionary<string,int>();
        readonly Server owner;
        volatile bool stopped;
        public Dictionary<string,byte[]> Files = new Dictionary<string,byte[]>();
        public string BaseUri { get; private set; }
        public string Fault = "";
        public Server DownloadTarget;
        public Record[] Requests { get { lock(records) return records.ToArray(); } }
        public Server() : this(null) { }
        public Server(Server storage) {
            owner = storage ?? this;
            if(storage != null) Files = storage.Files;
            using(var key = RSA.Create(2048)) {
                var req = new CertificateRequest("CN=localhost", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                var san = new SubjectAlternativeNameBuilder(); san.AddIpAddress(IPAddress.Loopback);
                req.CertificateExtensions.Add(san.Build());
                using(var cert = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddHours(2)))
                    certificate = new X509Certificate2(cert.Export(X509ContentType.Pfx), "", X509KeyStorageFlags.DefaultKeySet);
            }
            Certificates.Register(certificate.Thumbprint);
            listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
            BaseUri = "https://127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port + "/";
            thread = new Thread(Run); thread.IsBackground = true; thread.Start();
        }
        static string Line(Stream stream) {
            var bytes = new List<byte>(); int b;
            while((b = stream.ReadByte()) >= 0) { if(b == 10) break; if(b != 13) bytes.Add((byte)b); }
            return Encoding.ASCII.GetString(bytes.ToArray());
        }
        static string BodyPath(byte[] body) {
            var m = Regex.Match(Encoding.UTF8.GetString(body), "\"path\"\\s*:\\s*\"([^\"]+)\"");
            return m.Success ? m.Groups[1].Value : "";
        }
        void Run() {
            while(!stopped) {
                TcpClient client = null;
                try {
                    client = listener.AcceptTcpClient(); client.ReceiveTimeout=5000; client.SendTimeout=5000;
                    using(var stream = new SslStream(client.GetStream(), false)) {
                        stream.AuthenticateAsServer(certificate, false, SslProtocols.Tls12, false);
                        var first = Line(stream).Split(' '); if(first.Length != 3) continue;
                        var headers = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
                        string line; while(!String.IsNullOrEmpty(line=Line(stream))) {
                            int i=line.IndexOf(':'); if(i>0) headers[line.Substring(0,i)] = line.Substring(i+1).Trim();
                        }
                        if(headers.ContainsKey("Expect")) { var interim=Encoding.ASCII.GetBytes("HTTP/1.1 100 Continue\r\n\r\n"); stream.Write(interim,0,interim.Length); stream.Flush(); }
                        int length=headers.ContainsKey("Content-Length") ? Int32.Parse(headers["Content-Length"]) : 0;
                        var body=new byte[length]; int position=0;
                        while(position<length) { int n=stream.Read(body,position,length-position); if(n==0) throw new IOException(); position+=n; }
                        var record=new Record { Method=first[0], Path=first[1], FilePath=headers.ContainsKey("File-Path") ? Uri.UnescapeDataString(headers["File-Path"]) : "",
                            Authorization=headers.ContainsKey("Authorization"), Cookie=headers.ContainsKey("Cookie"), ProxyAuthorization=headers.ContainsKey("Proxy-Authorization") };
                        lock(records) records.Add(record);
                        int status=200; string type="application/json", location=null;
                        byte[] response=Encoding.UTF8.GetBytes("{\"code\":200}");
                        string path=record.Path;
                        if(path=="/api/auth/login") response=Encoding.UTF8.GetBytes("{\"code\":200,\"data\":{\"token\":\"fixture-token\"}}");
                        else if(path=="/api/me") response=Encoding.UTF8.GetBytes("{\"code\":200,\"data\":{\"disabled\":false,\"role\":0,\"permission\":8,\"base_path\":\"/fixture\"}}");
                        else if(path=="/api/fs/get") {
                            string p=BodyPath(body); bool exists; lock(Files) exists=Files.ContainsKey(p);
                            if(p=="/ota" || p=="/ota/objects" || p=="/ota/manifests") response=Encoding.UTF8.GetBytes("{\"code\":200,\"data\":{\"is_dir\":true}}");
                            else if(exists) response=Encoding.UTF8.GetBytes("{\"code\":200,\"data\":{\"is_dir\":false}}");
                            else response=Encoding.UTF8.GetBytes("{\"code\":500,\"message\":\"object not found\"}");
                        } else if(path=="/api/fs/put") {
                            if(Fault=="UploadRedirect") { status=302; location=DownloadTarget.BaseUri+"credential-leak"; }
                            else { if(Fault=="CorruptUpload" && body.Length>0) body[0]^=1; lock(Files) Files[record.FilePath]=body; }
                        } else if(path.StartsWith("/d/fixture/ota/",StringComparison.Ordinal)) {
                            status=302; location=DownloadTarget.BaseUri+"blob/"+path.Substring("/d/fixture/ota/".Length);
                            type="text/html"; response=Encoding.UTF8.GetBytes("<html>redirect</html>");
                        } else if(path.StartsWith("/blob/",StringComparison.Ordinal)) {
                            string relative=path.Substring(6), p="/ota/"+relative; type="application/octet-stream";
                            lock(Files) { if(!Files.TryGetValue(p,out response)) { response=new byte[0]; status=404; } }
                            int count; lock(owner.reads) { owner.reads.TryGetValue(relative,out count); owner.reads[relative]=++count; }
                            if(owner.Fault=="FinalSignature" && relative=="manifests/0.3.6.sig" && count>=2) response=Encoding.ASCII.GetBytes("invalid");
                            if(owner.Fault=="HtmlManifest" && relative.EndsWith(".json",StringComparison.Ordinal)) { type="text/html"; response=Encoding.UTF8.GetBytes("<html>login required</html>"); }
                        } else { status=404; response=new byte[0]; }
                        string head="HTTP/1.1 "+status+" Fixture\r\nContent-Length: "+response.Length+"\r\nConnection: close\r\nContent-Type: "+type+"\r\nSet-Cookie: admin-session=must-not-forward; Path=/\r\n";
                        if(location!=null) head+="Location: "+location+"\r\n";
                        var headBytes=Encoding.ASCII.GetBytes(head+"\r\n"); stream.Write(headBytes,0,headBytes.Length); stream.Write(response,0,response.Length); stream.Flush();
                    }
                } catch(Exception) { if(stopped) break; }
                finally { if(client!=null) client.Close(); }
            }
        }
        public void Dispose() { stopped=true; listener.Stop(); thread.Join(5500); certificate.Dispose(); }
    }
}
