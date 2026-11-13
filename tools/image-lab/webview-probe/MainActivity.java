package internal.artemis.webviewprobe;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.Bundle;
import android.os.IBinder;
import android.util.Log;
import android.webkit.ValueCallback;
import android.webkit.WebView;
import android.webkit.WebViewClient;

public final class MainActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        final String token = getIntent().getStringExtra("run_token");
        try {
            Intent service = new Intent("com.google.android.gms.common.service.START");
            service.setPackage("com.google.android.gms");
            boolean accepted = bindService(service, new ServiceConnection() {
                @Override public void onServiceConnected(ComponentName name, IBinder binder) {
                    Log.i("ArtemisWebProbe", "GMS_BIND_OK:" + token);
                    unbindService(this);
                }
                @Override public void onServiceDisconnected(ComponentName name) { }
            }, Context.BIND_AUTO_CREATE);
            if (!accepted) Log.e("ArtemisWebProbe", "GMS_BIND_REJECTED:" + token);
        } catch (Throwable error) {
            Log.e("ArtemisWebProbe", "GMS_BIND_FAILURE:" + token, error);
        }
        try {
            WebView view = new WebView(this);
            view.getSettings().setJavaScriptEnabled(true);
            view.setWebViewClient(new WebViewClient() {
                @Override public void onPageFinished(WebView v, String url) {
                    v.evaluateJavascript("document.title", new ValueCallback<String>() {
                        @Override public void onReceiveValue(String result) {
                            if ("\"ArtemisWebViewTest\"".equals(result)) {
                                Log.i("ArtemisWebProbe", "WEBVIEW_OK:" + token);
                            } else {
                                Log.e("ArtemisWebProbe", "WEBVIEW_BAD:" + token + ":" + result);
                            }
                        }
                    });
                }
            });
            setContentView(view);
            view.loadDataWithBaseURL(null, "<!doctype html><title>ArtemisWebViewTest</title><p>local test</p>",
                    "text/html", "UTF-8", null);
        } catch (Throwable error) {
            Log.e("ArtemisWebProbe", "WEBVIEW_FAILURE:" + token, error);
        }
    }
}
