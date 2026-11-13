using System;

namespace ArtemisOS.Frontend
{
    // Only explicit renderer failures count. A static Android screen is healthy
    // and must never be mistaken for a stalled stream.
    internal sealed class DisplayRecovery
    {
        private int frameFailures, attempts, episodeAttempts;
        private DateTime failureWindow, attemptWindow;

        public bool Observe(string line, DateTime now)
        {
            if (String.IsNullOrEmpty(line) || line.IndexOf("ERROR: Frame update failed", StringComparison.Ordinal) < 0)
                return false;
            if (frameFailures == 0 || now - failureWindow > TimeSpan.FromSeconds(2)) {
                frameFailures = 0;
                failureWindow = now;
            }
            return ++frameFailures >= 3;
        }

        public void ResetFrames() { frameFailures = 0; }
        public void BeginEpisode() { episodeAttempts = 0; }

        public bool TryRecover(DateTime now)
        {
            if (episodeAttempts >= 3) return false;
            if (attempts == 0 || now - attemptWindow >= TimeSpan.FromMinutes(1)) {
                attempts = 0;
                attemptWindow = now;
            }
            if (attempts >= 3) return false;
            attempts++;
            episodeAttempts++;
            return true;
        }
    }
}
