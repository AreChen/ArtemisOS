package cn.artemisos.updater;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Only the emulator's ADB shell may configure the per-launch host bridge. */
public final class BootstrapReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        String token = intent.getStringExtra("token");
        int port = intent.getIntExtra("port", 0);
        if (token == null || !token.matches("[0-9a-f]{64}") || port < 1024 || port > 65535) return;
        context.getSharedPreferences("host", Context.MODE_PRIVATE).edit()
            .putString("token", token).putInt("port", port).apply();
    }
}
