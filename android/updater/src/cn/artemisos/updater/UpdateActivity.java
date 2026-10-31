package cn.artemisos.updater;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

public final class UpdateActivity extends Activity {
    private TextView status;
    private Button check;

    @Override public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        int padding = (int) (24 * getResources().getDisplayMetrics().density);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setPadding(padding, padding, padding, padding);
        TextView title = new TextView(this);
        title.setText("ArtemisOS 更新");
        title.setTextSize(24);
        title.setGravity(Gravity.START);
        layout.addView(title);
        status = new TextView(this);
        status.setTextSize(16);
        status.setPadding(0, padding, 0, padding);
        status.setText("正在连接更新服务…");
        layout.addView(status);
        check = new Button(this);
        check.setText("检查更新");
        check.setOnClickListener(v -> runRequest("check"));
        layout.addView(check);
        setContentView(layout);
        runRequest("status");
    }

    private JSONObject request(String action) throws Exception {
        SharedPreferences prefs = getSharedPreferences("host", MODE_PRIVATE);
        String token = prefs.getString("token", "");
        int port = prefs.getInt("port", 0);
        if (!token.matches("[0-9a-f]{64}") || port < 1024 || port > 65535)
            throw new Exception("更新组件尚未就绪，请稍候或重启模拟器。");
        HttpURLConnection connection = (HttpURLConnection)
            new URL("http://10.0.2.2:" + port + "/v1/" + action).openConnection();
        connection.setConnectTimeout(5000);
        connection.setReadTimeout(action.equals("install") ? 180000 : 30000);
        connection.setRequestMethod(action.equals("status") ? "GET" : "POST");
        connection.setRequestProperty("X-Artemis-Token", token);
        if (!action.equals("status")) connection.setDoOutput(true);
        try {
            int responseCode = connection.getResponseCode();
            InputStream stream = responseCode < 400 ? connection.getInputStream() : connection.getErrorStream();
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            byte[] buffer = new byte[2048];
            int count;
            while ((count = stream.read(buffer)) != -1) {
                if (bytes.size() + count > 65536) throw new Exception("更新服务返回的数据过大。");
                bytes.write(buffer, 0, count);
            }
            JSONObject response = new JSONObject(new String(bytes.toByteArray(), StandardCharsets.UTF_8));
            if (responseCode >= 400 || !response.optBoolean("ok", false))
                throw new Exception(response.optString("message", "更新服务暂不可用。"));
            return response;
        } finally { connection.disconnect(); }
    }

    private void runRequest(String action) {
        check.setEnabled(false);
        status.setText(action.equals("check") ? "正在检查更新…" :
            action.equals("install") ? "正在下载和验证更新，请勿关闭模拟器…" : "正在连接更新服务…");
        new Thread(() -> {
            try {
                JSONObject response = request(action);
                runOnUiThread(() -> {
                    check.setEnabled(true);
                    if (action.equals("check") && response.optBoolean("available")) {
                        String version = response.optString("version");
                        String notes = response.optString("notes");
                        long size = response.optLong("size");
                        status.setText("发现新版本 " + version + "，约 " + ((size + 1023) / 1024) + " KB。");
                        new AlertDialog.Builder(this).setTitle("发现 ArtemisOS " + version)
                            .setMessage(notes + "\n\n更新时模拟器会关闭并重新启动。请先保存正在进行的工作。")
                            .setNegativeButton("稍后", null)
                            .setPositiveButton("下载并更新", (dialog, which) -> runRequest("install"))
                            .show();
                    } else {
                        status.setText(response.optString("message", "当前已是最新版本。"));
                    }
                });
            } catch (Exception error) {
                runOnUiThread(() -> {
                    check.setEnabled(true);
                    status.setText(error.getMessage() == null ? "连接更新服务失败。" : error.getMessage());
                });
            }
        }).start();
    }
}
