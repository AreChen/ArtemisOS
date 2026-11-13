package internal.artemis.abilab;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.widget.TextView;

public class MainActivity extends Activity {
    private static native int nativeProbe(int value);

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        TextView result = new TextView(this);
        String token = getIntent().getStringExtra("run_token");
        try {
            System.loadLibrary("armprobe");
            int value = nativeProbe(12345);
            String marker = (value == 37042 ? "ARM64_JNI_OK:" : "ARM64_JNI_BAD:") + value + ":" + token;
            Log.i("ArtemisAbiProbe", marker);
            result.setText(marker);
        } catch (Throwable error) {
            Log.e("ArtemisAbiProbe", "ARM64_JNI_FAILURE:" + token, error);
            result.setText("ARM64_JNI_FAILURE");
        }
        setContentView(result);
    }
}
