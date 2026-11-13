package com.artemisos.securedisplaytest;

import android.app.Activity;
import android.os.Bundle;
import android.graphics.Color;
import android.view.WindowManager;
import android.widget.LinearLayout;
import android.widget.TextView;

/** No credentials or user data: a deterministic FLAG_SECURE display fixture. */
public final class MainActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        boolean secure = getIntent().getBooleanExtra("secure", true);
        if (secure) getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setPadding(32, 80, 32, 32);
        layout.setBackgroundColor(secure ? Color.rgb(18, 180, 84) : Color.rgb(32, 96, 220));
        TextView title = new TextView(this);
        title.setText("Artemis display fixture\nFLAG_SECURE=" + (secure ? "ON" : "OFF")
                + "\n\nSynthetic test page\nNo password or personal data");
        title.setTextColor(Color.WHITE);
        title.setTextSize(25);
        layout.addView(title);
        setContentView(layout);
    }
}
