import React, { useState } from 'react';
import { View, useWindowDimensions } from 'react-native';
import { useRouter } from 'expo-router';
import {
  endActiveRideSession,
  setRelayMode,
} from '@/actions/cockpit';
import {
  filterContacts,
  formatBatteryLabel,
  isBatteryLow,
  resolveLinkBadge,
} from '@/core/cockpit';
import type { RelayMode } from '@/core/types';
import {
  dialContactNumber,
  disconnectCompanion,
  openNotificationAccessSettings,
  openTetheringSettings,
  seekMediaPosition,
  sendCockpitCommand,
  setBluetoothTetheringActive,
  startSenderServer,
  stopSenderServer,
  syncCompanionContacts,
} from '@/data/companion';
import { requestAllPillionPermissions } from '@/lib/permissions';
import { formatDurationMs } from '@/lib/time';
import { getStore, useAppState } from '@/state/app';
import {
  initCompanionBridge,
  refreshCompanionSnapshot,
  showVolumeHud,
  teardownPreviousRelayMode,
  useCompanionState,
  useVolumeHud,
} from '@/state/companion';
import { Button } from '@/ui/Button';
import { CallHudCard } from '@/ui/CallHudCard';
import { Card } from '@/ui/Card';
import { PocketGuardianCard } from '@/ui/PocketGuardianCard';
import { Icon } from '@/ui/Icon';
import { MediaSeekBar } from '@/ui/MediaSeekBar';
import { getPalette } from '@/ui/palette';
import { Press } from '@/ui/Press';
import { Segmented } from '@/ui/Segmented';
import { PageShell } from '@/ui/shells/PageShell';
import { ScreenScroll } from '@/ui/shells/ScreenScroll';
import { UpdateCard } from '@/ui/shells/UpdateCard';
import { Text } from '@/ui/Text';
import { showToast } from '@/ui/Toast';
import { VolumeHudCard } from '@/ui/VolumeHudCard';

export default function CockpitScreen() {
  const router = useRouter();
  const { width } = useWindowDimensions();
  const isWide = width >= 700;
  const { settings } = useAppState();
  const companion = useCompanionState();
  const volumeHud = useVolumeHud();
  const palette = getPalette(settings.theme);

  const [seekingInfo, setSeekingInfo] = useState<{ isSeeking: boolean; seekMs: number }>({
    isSeeking: false,
    seekMs: 0,
  });

  const favoriteContacts = filterContacts(companion.contacts, '').slice(0, 4);

  const handleVolumeAdjust = async (direction: 'up' | 'down') => {
    const cur = companion.volumePercent || 70;
    const next = direction === 'up' ? Math.min(100, cur + 7) : Math.max(0, cur - 7);
    showVolumeHud(next, false);
    await sendCockpitCommand(direction === 'up' ? '/volume/up' : '/volume/down');
  };

  const badge = resolveLinkBadge(
    companion.connectionStatus,
    companion.isServerRunning,
    companion.isCallActive
  );

  const badgeColor =
    badge.tone === 'active'
      ? palette.accent
      : badge.tone === 'alert'
        ? palette.danger
        : badge.tone === 'linking'
          ? palette.warning
          : palette.foregroundMuted;

  const lowBattery = isBatteryLow(companion.batteryLevel);

  const handleModeChange = async (mode: RelayMode) => {
    if (mode === settings.relayMode) return;
    const prev = settings.relayMode;
    await setRelayMode(getStore(), mode);
    await teardownPreviousRelayMode(prev);
    await initCompanionBridge(mode);
    await refreshCompanionSnapshot();
  };

  const handleToggleTethering = async () => {
    const nextState = !companion.isBluetoothTetheringOn;
    const ok = await setBluetoothTetheringActive(nextState);
    if (!ok) {
      showToast('Opening system tethering settings...', 'info');
      await openTetheringSettings();
    } else {
      showToast(
        nextState ? 'Bluetooth Internet Relay enabled' : 'Bluetooth Internet Relay disabled',
        'success'
      );
    }
    await refreshCompanionSnapshot();
  };

  const handleStartServer = async () => {
    const granted = await requestAllPillionPermissions('sender');
    if (!granted) {
      showToast('Bluetooth and phone permissions are required to relay alerts', 'error');
      return;
    }
    const snap = await refreshCompanionSnapshot();
    if (!snap.hasNotificationAccess) {
      showToast('Enable Notification Access for Cockpit', 'info');
      await openNotificationAccessSettings();
      return;
    }
    await startSenderServer();
    await refreshCompanionSnapshot();
    showToast('Cockpit Relay Server broadcasting', 'success');
  };

  const handleConnectFlow = async () => {
    const granted = await requestAllPillionPermissions('receiver');
    if (!granted) {
      showToast('Bluetooth permission is required to list paired phones', 'error');
      return;
    }
    router.push('/connect');
  };

  return (
    <PageShell
      title="Cockpit"
      eyebrow={settings.relayMode === 'sender' ? 'PRIMARY PHONE RELAY' : 'HANDLEBAR DISPLAY'}
      rightSlot={
        <View className="flex-row items-center gap-1.5 rounded-xs border-[1.5px] border-border bg-surface px-2.5 py-1.5 shrink-0">
          <View
            style={{ backgroundColor: badgeColor }}
            className="h-2 w-2 rounded-full"
          />
          <Text style={{ color: badgeColor }} className="font-mono-bold text-xs">
            {badge.label}
          </Text>
          <Text className="font-mono text-xs text-foreground-muted">•</Text>
          <Icon
            name="battery"
            size={13}
            color={lowBattery ? palette.danger : palette.foreground}
          />
          <Text
            className={`font-mono-bold text-xs ${
              lowBattery ? 'text-danger' : 'text-foreground'
            }`}
          >
            {formatBatteryLabel(companion.batteryLevel)}
          </Text>
        </View>
      }
    >
      <ScreenScroll>
        <Segmented
          options={[
            { value: 'sender', label: 'Primary Phone' },
            { value: 'receiver', label: 'Handlebar OS' },
          ]}
          value={settings.relayMode}
          onChange={handleModeChange}
        />

        <UpdateCard />

        {/* Live Call HUD & Pocket Guardian Watchdog */}
        <CallHudCard companion={companion} />
        <PocketGuardianCard companion={companion} />

        <VolumeHudCard
          visible={volumeHud.visible}
          percent={volumeHud.percent}
          isAuto={volumeHud.isAuto}
          speedKmh={companion.currentSpeedKmh}
        />

        {settings.relayMode === 'sender' ? (
          <View className="gap-4">
            {/* Bluetooth Internet Relay (Tethering / PAN) */}
            <Card className="gap-3">
              <View className="flex-row items-center justify-between">
                <View className="flex-row items-center gap-2">
                  <Icon
                    name="wifi"
                    size={18}
                    color={companion.isBluetoothTetheringOn ? palette.accent : palette.foregroundMuted}
                  />
                  <Text className="font-mono text-xs uppercase tracking-widest text-foreground-muted">
                    BLUETOOTH INTERNET RELAY
                  </Text>
                </View>
                <View
                  className="flex-row items-center gap-1.5 px-2 py-0.5 rounded border"
                  style={{
                    borderColor: companion.isBluetoothTetheringOn ? palette.accent : palette.border,
                    backgroundColor: companion.isBluetoothTetheringOn ? `${palette.accent}20` : 'transparent',
                  }}
                >
                  <View
                    className="h-1.5 w-1.5 rounded-full"
                    style={{
                      backgroundColor: companion.isBluetoothTetheringOn
                        ? palette.accent
                        : palette.foregroundMuted,
                    }}
                  />
                  <Text
                    className="font-mono-bold text-[10px]"
                    style={{
                      color: companion.isBluetoothTetheringOn
                        ? palette.accent
                        : palette.foregroundMuted,
                    }}
                  >
                    {companion.isBluetoothTetheringOn ? 'TETHERING ON' : 'STANDBY'}
                  </Text>
                </View>
              </View>

              <Text className="text-sm text-foreground-muted leading-relaxed">
                Relays this phone&apos;s cellular internet over Bluetooth PAN to Cockpit OS on your bike.
                Allows handlebar maps to fetch live traffic, routing updates, and offline tile data without a separate SIM card.
              </Text>

              <View className="flex-row gap-2.5">
                <Button
                  label={companion.isBluetoothTetheringOn ? 'Disable Relay' : 'Enable Relay'}
                  icon={companion.isBluetoothTetheringOn ? 'check' : 'radio'}
                  tone={companion.isBluetoothTetheringOn ? 'surface' : 'primary'}
                  compact
                  onPress={handleToggleTethering}
                  className="flex-1"
                />
                <Button
                  label="Settings"
                  icon="settings"
                  tone="surface"
                  compact
                  onPress={() => openTetheringSettings()}
                  className="flex-1"
                />
              </View>
            </Card>

            <View className={isWide ? 'flex-row items-start gap-4' : 'gap-4'}>
              {/* Active Media Deck */}
              <Card className={isWide ? 'flex-1 gap-4' : 'gap-4'}>
                <View className="gap-2">
                  <View className="flex-row items-center justify-between gap-2">
                    <Text className="font-mono text-xs uppercase tracking-widest text-foreground-muted">
                      MEDIA STREAMING
                    </Text>
                    {companion.durationMs > 0 ? (
                      <Text
                        className={`font-mono-bold text-sm shrink-0 ${
                          seekingInfo.isSeeking ? 'text-accent' : 'text-primary'
                        }`}
                      >
                        {formatDurationMs(
                          seekingInfo.isSeeking ? seekingInfo.seekMs : companion.progressMs
                        )}{' '}
                        / {formatDurationMs(companion.durationMs)}
                      </Text>
                    ) : null}
                  </View>

                  <View className="gap-0.5 min-w-0">
                    <Text className="font-bold text-2xl text-foreground leading-tight" numberOfLines={2}>
                      {companion.songTitle}
                    </Text>
                    <Text className="text-base text-foreground-muted leading-snug" numberOfLines={2}>
                      {companion.artistName}
                    </Text>
                  </View>
                </View>

                <MediaSeekBar
                  progressMs={companion.progressMs}
                  durationMs={companion.durationMs}
                  onSeek={(targetMs) => {
                    void seekMediaPosition(targetMs);
                  }}
                  onSeekingChange={(isSeeking, currentSeekMs) => {
                    setSeekingInfo({ isSeeking, seekMs: currentSeekMs });
                  }}
                />

                <View className="flex-row gap-2.5">
                  <Press
                    onPress={() => sendCockpitCommand('/media/prev')}
                    accessibilityLabel="Previous track"
                    className="w-16 min-h-[64px] items-center justify-center rounded-sm border-[1.5px] border-border bg-surface-muted active:border-primary"
                  >
                    <Icon name="skipBack" size={24} color={palette.foreground} />
                  </Press>
                  <Press
                    onPress={() => sendCockpitCommand('/media/playpause')}
                    haptic="confirm"
                    accessibilityLabel={companion.isPlaying ? 'Pause' : 'Play'}
                    className="flex-1 min-h-[64px] flex-row items-center justify-center gap-2 rounded-sm border-[1.5px] border-primary bg-primary active:opacity-90"
                  >
                    <Icon
                      name={companion.isPlaying ? 'pause' : 'play'}
                      size={24}
                      color={palette.onPrimary}
                    />
                    <Text className="font-bold text-lg text-on-primary tracking-wide">
                      {companion.isPlaying ? 'PAUSE' : 'PLAY'}
                    </Text>
                  </Press>
                  <Press
                    onPress={() => sendCockpitCommand('/media/next')}
                    accessibilityLabel="Next track"
                    className="w-16 min-h-[64px] items-center justify-center rounded-sm border-[1.5px] border-border bg-surface-muted active:border-primary"
                  >
                    <Icon name="skipForward" size={24} color={palette.foreground} />
                  </Press>
                </View>

                <View className="flex-row gap-2.5">
                  <Button
                    label="Vol -"
                    icon="volumeMute"
                    tone="surface"
                    compact
                    onPress={() => handleVolumeAdjust('down')}
                    className="flex-1"
                  />
                  <Button
                    label="Vol +"
                    icon="volume"
                    tone="surface"
                    compact
                    onPress={() => handleVolumeAdjust('up')}
                    className="flex-1"
                  />
                </View>
              </Card>

              {/* Quick Dial Contacts */}
              <View className={isWide ? 'flex-1 gap-4' : 'gap-4'}>
                <Card className="gap-3">
                  <View className="flex-row items-center justify-between">
                    <Text className="font-mono text-xs uppercase tracking-widest text-foreground-muted">
                      QUICK DIAL
                    </Text>
                    <Press
                      onPress={() => router.push('/(tabs)/phone')}
                      className="px-2.5 py-1 rounded-xs border-[1.5px] border-border bg-surface-muted"
                    >
                      <Text className="font-mono-bold text-xs text-primary">OPEN PHONE</Text>
                    </Press>
                  </View>
                  {favoriteContacts.length === 0 ? (
                    <Text className="text-sm text-foreground-muted">
                      Contacts will sync automatically when Cockpit OS connects.
                    </Text>
                  ) : (
                    <View className="flex-row flex-wrap gap-2">
                      {favoriteContacts.map((contact) => (
                        <Press
                          key={contact.id}
                          onPress={async () => {
                            await dialContactNumber(contact.phoneNumber);
                            showToast(`Dialing ${contact.name}`, 'success');
                          }}
                          haptic="confirm"
                          className="min-w-[46%] flex-1 flex-row items-center gap-2.5 rounded-sm border-[1.5px] border-border bg-surface-muted px-3 py-3 min-h-[58px]"
                        >
                          <View className="h-8 w-8 rounded-full items-center justify-center bg-accent/15 border border-accent/40 shrink-0">
                            <Icon name="phoneCall" size={14} color={palette.accent} />
                          </View>
                          <View className="flex-1 min-w-0">
                            <Text className="font-bold text-sm text-foreground leading-tight" numberOfLines={2}>
                              {contact.name}
                            </Text>
                          </View>
                        </Press>
                      ))}
                    </View>
                  )}
                </Card>

                {/* SPP Broadcast Server & Access */}
                <Card className="gap-3">
                  <View className="flex-row items-center justify-between">
                    <Text className="font-mono text-xs uppercase tracking-widest text-foreground-muted">
                      COCKPIT RELAY SERVER
                    </Text>
                    <Text
                      className="font-mono-bold text-xs"
                      style={{ color: companion.isServerRunning ? palette.accent : palette.foregroundMuted }}
                    >
                      {companion.isServerRunning ? 'LISTENING' : 'OFFLINE'}
                    </Text>
                  </View>
                  <Text className="text-sm text-foreground-muted">
                    Keep this phone in your pocket. Cockpit OS on your handlebars will automatically pair and mirror music, calls, and notifications over SPP.
                  </Text>

                  {companion.isServerRunning ? (
                    <Button
                      label="Stop Relay Server"
                      icon="bluetoothOff"
                      tone="danger"
                      onPress={async () => {
                        await stopSenderServer();
                        await refreshCompanionSnapshot();
                      }}
                    />
                  ) : (
                    <Button
                      label="Start Relay Server"
                      icon="radio"
                      tone="primary"
                      onPress={handleStartServer}
                    />
                  )}
                </Card>
              </View>
            </View>

            {/* Access & Sync Configuration */}
            <Card className="gap-3">
              <Text className="font-mono text-xs uppercase tracking-widest text-foreground-muted">
                PERMISSIONS & SYNC
              </Text>
              <View className="flex-row flex-wrap gap-2.5">
                <Button
                  label={
                    companion.hasRuntimePermissions
                      ? 'Bluetooth & Calls Active'
                      : 'Grant Bluetooth & Calls'
                  }
                  icon={companion.hasRuntimePermissions ? 'check' : 'shield'}
                  tone={companion.hasRuntimePermissions ? 'surface' : 'primary'}
                  compact
                  onPress={async () => {
                    await requestAllPillionPermissions('sender');
                    await refreshCompanionSnapshot();
                  }}
                  className="flex-1 min-w-[200px]"
                />
                <Button
                  label={
                    companion.hasNotificationAccess
                      ? 'Notification Listener Active'
                      : 'Enable Notification Access'
                  }
                  icon={companion.hasNotificationAccess ? 'check' : 'bell'}
                  tone={companion.hasNotificationAccess ? 'surface' : 'primary'}
                  compact
                  onPress={() => openNotificationAccessSettings()}
                  className="flex-1 min-w-[200px]"
                />
                <Button
                  label="Force Sync Contacts & Recents"
                  icon="users"
                  tone="surface"
                  compact
                  onPress={async () => {
                    await syncCompanionContacts();
                    await refreshCompanionSnapshot();
                    showToast('Contacts and call logs synced', 'success');
                  }}
                  className="w-full"
                />
              </View>
            </Card>
          </View>
        ) : (
          /* Receiver fallback view for handlebar testing */
          <View className="gap-4">
            <Card className="gap-3">
              <View className="flex-row items-center justify-between">
                <Text className="font-mono text-xs uppercase tracking-widest text-foreground-muted">
                  HANDLEBAR RECEIVER MODE
                </Text>
                <Icon name="smartphone" size={16} color={palette.primary} />
              </View>
              <Text className="text-sm text-foreground-muted">
                Handlebar receiver features are native inside Cockpit OS on the Moto G52. If using an external device as handlebar display, connect below:
              </Text>
              <Button
                label={
                  companion.connectionStatus === 'Connected'
                    ? 'Switch Primary Phone'
                    : 'Connect Primary Phone'
                }
                icon="bluetooth"
                tone="primary"
                onPress={handleConnectFlow}
              />
              {companion.connectionStatus === 'Connected' ? (
                <Button
                  label="Disconnect Primary Phone"
                  icon="bluetoothOff"
                  tone="danger"
                  onPress={async () => {
                    await disconnectCompanion();
                    await endActiveRideSession(getStore()).catch(() => {});
                  }}
                />
              ) : null}
            </Card>
          </View>
        )}
      </ScreenScroll>
    </PageShell>
  );
}
