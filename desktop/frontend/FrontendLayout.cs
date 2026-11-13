using System;
using System.Drawing;

namespace ArtemisOS.Frontend
{
    public sealed class FrontendLayout
    {
        public Rectangle Header, Video, Toolbar, Footer;

        public static Size WindowForVideo(Size video, int longEdge, double scale)
        {
            double factor = longEdge / (double)Math.Max(video.Width, video.Height);
            int pad = (int)Math.Round(14 * scale);
            int chromeWidth = (int)Math.Round(52 * scale) + pad * 3;
            int chromeHeight = (int)Math.Round(65 * scale) + (int)Math.Round(35 * scale) + pad * 2;
            return new Size((int)Math.Round(video.Width * factor) + chromeWidth,
                (int)Math.Round(video.Height * factor) + chromeHeight);
        }

        public static FrontendLayout Calculate(Size client, double scale, Size video)
        {
            if (scale <= 0 || video.Width <= 0 || video.Height <= 0)
                throw new ArgumentOutOfRangeException("scale");
            int pad = (int)Math.Round(14 * scale);
            int head = (int)Math.Round(65 * scale);
            int foot = (int)Math.Round(35 * scale);
            int rail = (int)Math.Round(52 * scale);
            var result = new FrontendLayout();
            result.Header = new Rectangle(0, 0, client.Width, head);
            result.Footer = new Rectangle(0, Math.Max(head, client.Height - foot), client.Width, foot);
            result.Toolbar = new Rectangle(client.Width - pad - rail, head + pad, rail,
                Math.Max(1, client.Height - head - foot - pad * 2));
            int aw = Math.Max(1, result.Toolbar.Left - pad * 2);
            int ah = Math.Max(1, result.Footer.Top - head - pad * 2);
            double fit = Math.Min(aw / (double)video.Width, ah / (double)video.Height);
            int w = Math.Max(1, (int)Math.Round(video.Width * fit));
            int h = Math.Max(1, (int)Math.Round(video.Height * fit));
            result.Video = new Rectangle(pad + (aw - w) / 2, head + pad + (ah - h) / 2, w, h);
            return result;
        }
    }
}
