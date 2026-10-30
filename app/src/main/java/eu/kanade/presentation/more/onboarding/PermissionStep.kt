package eu.kanade.presentation.more.onboarding

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.getSystemService
import androidx.core.net.toUri
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.compose.LocalLifecycleOwner
import eu.kanade.tachiyomi.util.system.telemetryIncluded
import mihon.app.di.appGraph
import mihon.icons.materialsymbols.MaterialSymbols
import tachiyomi.i18n.MR
import tachiyomi.presentation.core.i18n.stringResource
import tachiyomi.presentation.core.util.collectAsState
import tachiyomi.presentation.core.util.secondaryItemAlpha

internal class PermissionStep : OnboardingStep {

    private var installGranted by mutableStateOf(false)
    private var notificationGranted by mutableStateOf(false)
    private var batteryGranted by mutableStateOf(false)

    override val isComplete: Boolean = true

    private fun refreshPermissions(context: Context) {
        installGranted = context.packageManager.canRequestPackageInstalls()
        notificationGranted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
        batteryGranted = context.getSystemService<PowerManager>()!!
            .isIgnoringBatteryOptimizations(context.packageName)
    }

    @Composable
    override fun Content() {
        val context = LocalContext.current
        val privacyPreferences = remember { context.appGraph.privacyPreferences }
        // Docho: watch the activity itself, the screen's lifecycle owner doesn't always resume after a system prompt
        val lifecycleOwner = (LocalActivity.current as? LifecycleOwner) ?: LocalLifecycleOwner.current

        DisposableEffect(lifecycleOwner.lifecycle) {
            val observer = object : DefaultLifecycleObserver {
                override fun onResume(owner: LifecycleOwner) {
                    refreshPermissions(context)
                }
            }
            lifecycleOwner.lifecycle.addObserver(observer)
            onDispose {
                lifecycleOwner.lifecycle.removeObserver(observer)
            }
        }

        val settingsLauncher = rememberLauncherForActivityResult(
            contract = ActivityResultContracts.StartActivityForResult(),
            onResult = { refreshPermissions(context) },
        )

        Column {
            PermissionCheckbox(
                title = stringResource(MR.strings.onboarding_permission_install_apps),
                subtitle = stringResource(MR.strings.onboarding_permission_install_apps_description),
                granted = installGranted,
                onButtonClick = {
                    settingsLauncher.launch(
                        Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, "package:${context.packageName}".toUri()),
                    )
                },
            )

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val permissionRequester = rememberLauncherForActivityResult(
                    contract = ActivityResultContracts.RequestPermission(),
                    onResult = { refreshPermissions(context) },
                )
                PermissionCheckbox(
                    title = stringResource(MR.strings.onboarding_permission_notifications),
                    subtitle = stringResource(MR.strings.onboarding_permission_notifications_description),
                    granted = notificationGranted,
                    onButtonClick = { permissionRequester.launch(Manifest.permission.POST_NOTIFICATIONS) },
                )
            }

            PermissionCheckbox(
                title = stringResource(MR.strings.onboarding_permission_ignore_battery_opts),
                subtitle = stringResource(MR.strings.onboarding_permission_ignore_battery_opts_description),
                granted = batteryGranted,
                onButtonClick = {
                    @SuppressLint("BatteryLife")
                    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                        data = "package:${context.packageName}".toUri()
                    }
                    settingsLauncher.launch(intent)
                },
            )

            if (!telemetryIncluded) return@Column

            HorizontalDivider(
                modifier = Modifier.padding(vertical = 8.dp, horizontal = 16.dp),
                color = MaterialTheme.colorScheme.onPrimaryContainer,
            )

            val crashlyticsPref = privacyPreferences.crashlytics
            val crashlytics by crashlyticsPref.collectAsState()
            PermissionSwitch(
                title = stringResource(MR.strings.onboarding_permission_crashlytics),
                subtitle = stringResource(MR.strings.onboarding_permission_crashlytics_description),
                granted = crashlytics,
                onToggleChange = crashlyticsPref::set,
            )

            val analyticsPref = privacyPreferences.analytics
            val analytics by analyticsPref.collectAsState()
            PermissionSwitch(
                title = stringResource(MR.strings.onboarding_permission_analytics),
                subtitle = stringResource(MR.strings.onboarding_permission_analytics_description),
                granted = analytics,
                onToggleChange = analyticsPref::set,
            )
        }
    }

    @Composable
    private fun SectionHeader(
        text: String,
        modifier: Modifier = Modifier,
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.titleLarge,
            modifier = modifier
                .padding(horizontal = 16.dp)
                .secondaryItemAlpha(),
        )
    }

    @Composable
    private fun PermissionCheckbox(
        title: String,
        subtitle: String,
        granted: Boolean,
        modifier: Modifier = Modifier,
        onButtonClick: () -> Unit,
    ) {
        ListItem(
            modifier = modifier,
            trailingContent = {
                OutlinedButton(
                    enabled = !granted,
                    onClick = onButtonClick,
                    colors = ButtonDefaults.outlinedButtonColors(disabledContentColor = GrantedColor),
                    border = if (granted) BorderStroke(1.dp, GrantedColor) else ButtonDefaults.outlinedButtonBorder(),
                ) {
                    if (granted) {
                        Text(stringResource(MR.strings.onboarding_permission_granted))
                    } else {
                        Text(stringResource(MR.strings.onboarding_permission_action_grant))
                    }
                }
            },
            supportingContent = { Text(text = subtitle) },
            colors = ListItemDefaults.colors(containerColor = Color.Transparent),
            content = { Text(text = title) },
        )
    }

    @Composable
    private fun PermissionSwitch(
        title: String,
        subtitle: String,
        granted: Boolean,
        modifier: Modifier = Modifier,
        onToggleChange: (Boolean) -> Unit,
    ) {
        ListItem(
            modifier = modifier,
            trailingContent = {
                Switch(
                    checked = granted,
                    onCheckedChange = onToggleChange,
                )
            },
            supportingContent = { Text(text = subtitle) },
            colors = ListItemDefaults.colors(containerColor = Color.Transparent),
            content = { Text(text = title) },
        )
    }
}

/** Readable on both light and dark backgrounds. */
private val GrantedColor = Color(0xFF43A047)
