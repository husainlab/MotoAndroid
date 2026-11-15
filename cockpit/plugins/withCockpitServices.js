const { withAndroidManifest } = require('expo/config-plugins');

/**
 * Ensures AndroidManifest declares required features and registers
 * Cockpit's native NotificationListenerService on the primary phone.
 */
module.exports = function withCockpitServices(config) {
  return withAndroidManifest(config, (mod) => {
    const manifest = mod.modResults.manifest;

    manifest['uses-feature'] = manifest['uses-feature'] || [];
    const requiredFeatures = [
      'android.hardware.telephony',
      'android.hardware.bluetooth',
    ];
    for (const feature of requiredFeatures) {
      const exists = manifest['uses-feature'].some(
        (f) => f.$['android:name'] === feature
      );
      if (!exists) {
        manifest['uses-feature'].push({
          $: {
            'android:name': feature,
            'android:required': 'false',
          },
        });
      }
    }

    const app = manifest.application?.[0];
    if (!app) return mod;
    app.service = app.service || [];

    const listenerName = 'com.husainlab.pillion.nativecore.PillionNotificationListener';
    if (!app.service.some((s) => s.$['android:name'] === listenerName)) {
      app.service.push({
        $: {
          'android:name': listenerName,
          'android:label': 'Cockpit Notification Listener',
          'android:permission': 'android.permission.BIND_NOTIFICATION_LISTENER_SERVICE',
          'android:exported': 'true',
        },
        'intent-filter': [
          {
            action: [
              {
                $: {
                  'android:name': 'android.service.notification.NotificationListenerService',
                },
              },
            ],
          },
        ],
      });
    }

    // Configure Cockpit MainActivity as Default System Launcher (HOME Category)
    const mainActivity = app.activity?.find(
      (a) => a.$['android:name'] === '.MainActivity'
    );
    if (mainActivity) {
      mainActivity['intent-filter'] = mainActivity['intent-filter'] || [];
      const mainFilter = mainActivity['intent-filter'].find((filter) =>
        filter.action?.some((a) => a.$['android:name'] === 'android.intent.action.MAIN')
      );
      if (mainFilter) {
        mainFilter.category = mainFilter.category || [];
        const requiredCategories = [
          'android.intent.category.LAUNCHER',
          'android.intent.category.HOME',
          'android.intent.category.DEFAULT',
        ];
        for (const cat of requiredCategories) {
          if (!mainFilter.category.some((c) => c.$['android:name'] === cat)) {
            mainFilter.category.push({
              $: { 'android:name': cat },
            });
          }
        }
      }
    }

    return mod;
  });
};
