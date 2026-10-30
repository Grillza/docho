package eu.kanade.presentation.more.settings.screen

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.DrawableRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import doki.sync.InvalidSyncSettingsFileException
import doki.sync.ProgressSyncMode
import doki.sync.SyncSettingsFile
import doki.sync.WrongPasswordException
import eu.kanade.presentation.more.settings.Preference
import eu.kanade.tachiyomi.util.system.toast
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import mihon.app.di.appGraph
import mihon.icons.materialsymbols.MaterialSymbols
import mihon.icons.materialsymbols.rounded.Visibility
import mihon.icons.materialsymbols.rounded.VisibilityOff
import tachiyomi.core.common.i18n.pluralStringResource
import tachiyomi.core.common.i18n.stringResource
import tachiyomi.i18n.MR
import tachiyomi.presentation.core.components.material.padding
import tachiyomi.presentation.core.i18n.stringResource

private const val MIN_PASSWORD_LENGTH = 8

/** The servers Doki reads from and syncs with, and where reading progress is synced. */
object SettingsSyncScreen : SearchableSettings {

    @ReadOnlyComposable
    @Composable
    override fun getTitleRes() = MR.strings.pref_category_sync

    @Composable
    override fun getPreferences(): List<Preference> {
        return listOf(
            getModeGroup(),
            KavitaSettingsGroup.getGroup(),
            BookOrbitSettingsGroup.getGroup(),
            KomgaSettingsGroup.getGroup(),
            KoreaderSettingsGroup.getGroup(),
            getSettingsFileGroup(),
        )
    }

    /** Export and import of these settings, to set up another device the same way. */
    @Composable
    private fun getSettingsFileGroup(): Preference.PreferenceGroup {
        val context = LocalContext.current
        val scope = rememberCoroutineScope()
        val settingsFile = remember { context.appGraph.syncSettingsFile }
        var exporting by remember { mutableStateOf(false) }
        // What to export, kept from the dialog until a file has been picked, then forgotten.
        var pendingExport by remember { mutableStateOf<Pair<Boolean, String?>?>(null) }
        // An encrypted file waiting for its password.
        var pendingImport by remember { mutableStateOf<String?>(null) }
        var wrongPassword by remember { mutableStateOf(false) }
        var decrypting by remember { mutableStateOf(false) }

        fun reportImport(result: Result<Int>) {
            context.toast(
                result.fold(
                    onSuccess = { context.pluralStringResource(MR.plurals.sync_settings_imported, it, it) },
                    onFailure = { context.stringResource(MR.strings.sync_settings_import_failed) },
                ),
            )
        }

        val exportLauncher = rememberLauncherForActivityResult(
            ActivityResultContracts.CreateDocument(SyncSettingsFile.MIME_TYPE),
        ) { uri ->
            val (includeSignIn, password) = pendingExport ?: return@rememberLauncherForActivityResult
            pendingExport = null
            if (uri == null) return@rememberLauncherForActivityResult
            scope.launch {
                val saved = withContext(Dispatchers.IO) {
                    runCatching {
                        val text = settingsFile.export(includeSignIn, password)
                        context.contentResolver.openOutputStream(uri, "wt")!!.use { it.write(text.toByteArray()) }
                    }
                }
                context.toast(
                    when {
                        saved.isFailure -> MR.strings.sync_settings_export_failed
                        password != null -> MR.strings.sync_settings_exported_encrypted
                        else -> MR.strings.sync_settings_exported
                    },
                )
            }
        }
        val importLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            if (uri == null) return@rememberLauncherForActivityResult
            scope.launch {
                val text = withContext(Dispatchers.IO) {
                    runCatching { context.contentResolver.openInputStream(uri)!!.use { it.reader().readText() } }
                }.getOrNull()
                if (text != null && settingsFile.isEncrypted(text)) {
                    wrongPassword = false
                    pendingImport = text
                    return@launch
                }
                reportImport(
                    withContext(Dispatchers.IO) {
                        runCatching { settingsFile.import(text ?: throw InvalidSyncSettingsFileException()) }
                    },
                )
            }
        }

        if (exporting) {
            ExportDialog(
                onDismissRequest = { exporting = false },
                onExport = { includeSignIn, password ->
                    exporting = false
                    pendingExport = includeSignIn to password
                    exportLauncher.launch(SyncSettingsFile.FILE_NAME)
                },
            )
        }
        pendingImport?.let { text ->
            ImportPasswordDialog(
                wrongPassword = wrongPassword,
                checking = decrypting,
                onDismissRequest = { pendingImport = null },
                onImport = { password ->
                    decrypting = true
                    scope.launch {
                        val result = withContext(Dispatchers.IO) { runCatching { settingsFile.import(text, password) } }
                        decrypting = false
                        if (result.exceptionOrNull() is WrongPasswordException) {
                            wrongPassword = true
                        } else {
                            pendingImport = null
                            reportImport(result)
                        }
                    }
                },
            )
        }

        return Preference.PreferenceGroup(
            title = stringResource(MR.strings.pref_sync_settings_file),
            preferenceItems = listOf(
                Preference.PreferenceItem.TextPreference(
                    title = stringResource(MR.strings.pref_sync_settings_export),
                    subtitle = stringResource(MR.strings.pref_sync_settings_export_summary),
                    onClick = { exporting = true },
                ),
                Preference.PreferenceItem.TextPreference(
                    title = stringResource(MR.strings.pref_sync_settings_import),
                    subtitle = stringResource(MR.strings.pref_sync_settings_import_summary),
                    // Some file managers don't label .json files as JSON.
                    onClick = {
                        importLauncher.launch(
                            arrayOf(SyncSettingsFile.MIME_TYPE, "application/octet-stream", "text/plain"),
                        )
                    },
                ),
            ),
        )
    }

    /**
     * Asks for a password to encrypt the file with, and whether to include sign-in details,
     * which are only exported encrypted.
     */
    @Composable
    private fun ExportDialog(
        onDismissRequest: () -> Unit,
        onExport: (includeSignIn: Boolean, password: String?) -> Unit,
    ) {
        var password by remember { mutableStateOf("") }
        var confirm by remember { mutableStateOf("") }
        var includeSignIn by remember { mutableStateOf(false) }
        val tooShort = password.isNotEmpty() && password.length < MIN_PASSWORD_LENGTH
        val mismatch = confirm.isNotEmpty() && confirm != password
        val canExport = !tooShort && confirm == password && (!includeSignIn || password.isNotEmpty())

        AlertDialog(
            onDismissRequest = onDismissRequest,
            title = { Text(text = stringResource(MR.strings.pref_sync_settings_export)) },
            text = {
                Column(
                    modifier = Modifier.verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(MaterialTheme.padding.small),
                ) {
                    Text(text = stringResource(MR.strings.sync_settings_password_text))
                    PasswordField(
                        value = password,
                        onValueChange = { password = it },
                        label = stringResource(MR.strings.password),
                        isError = tooShort,
                        supportingText = when {
                            tooShort -> stringResource(MR.strings.sync_settings_password_too_short, MIN_PASSWORD_LENGTH)
                            includeSignIn -> stringResource(MR.strings.sync_settings_password_needed)
                            else -> stringResource(MR.strings.sync_settings_password_optional)
                        },
                    )
                    if (password.isNotEmpty()) {
                        PasswordField(
                            value = confirm,
                            onValueChange = { confirm = it },
                            label = stringResource(MR.strings.sync_settings_password_confirm),
                            isError = mismatch,
                            supportingText = stringResource(MR.strings.sync_settings_password_mismatch)
                                .takeIf { mismatch },
                        )
                    }
                    // The whole row ticks the box, not only the box itself.
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .toggleable(
                                value = includeSignIn,
                                role = Role.Checkbox,
                                onValueChange = { includeSignIn = it },
                            ),
                    ) {
                        Checkbox(checked = includeSignIn, onCheckedChange = null)
                        Column(modifier = Modifier.padding(start = MaterialTheme.padding.small)) {
                            Text(text = stringResource(MR.strings.sync_settings_sign_in_include))
                            Text(
                                text = stringResource(MR.strings.sync_settings_sign_in_summary),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(
                    onClick = { onExport(includeSignIn, password.ifEmpty { null }) },
                    enabled = canExport,
                ) {
                    Text(text = stringResource(MR.strings.action_export))
                }
            },
            dismissButton = {
                TextButton(onClick = onDismissRequest) {
                    Text(text = stringResource(MR.strings.action_cancel))
                }
            },
        )
    }

    /** Asks for an encrypted file's password, saying so when the last one was wrong. */
    @Composable
    private fun ImportPasswordDialog(
        wrongPassword: Boolean,
        checking: Boolean,
        onDismissRequest: () -> Unit,
        onImport: (String) -> Unit,
    ) {
        var password by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = onDismissRequest,
            title = { Text(text = stringResource(MR.strings.sync_settings_import_password_title)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(MaterialTheme.padding.small)) {
                    Text(text = stringResource(MR.strings.sync_settings_import_password_text))
                    PasswordField(
                        value = password,
                        onValueChange = { password = it },
                        label = stringResource(MR.strings.password),
                        isError = wrongPassword,
                        supportingText = when {
                            checking -> stringResource(MR.strings.sync_settings_password_checking)
                            wrongPassword -> stringResource(MR.strings.sync_settings_password_wrong)
                            else -> null
                        },
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = { onImport(password) }, enabled = password.isNotEmpty() && !checking) {
                    Text(text = stringResource(MR.strings.action_import))
                }
            },
            dismissButton = {
                TextButton(onClick = onDismissRequest) {
                    Text(text = stringResource(MR.strings.action_cancel))
                }
            },
        )
    }

    /** A password box with a button to show what's typed. */
    @Composable
    private fun PasswordField(
        value: String,
        onValueChange: (String) -> Unit,
        label: String,
        isError: Boolean,
        supportingText: String?,
    ) {
        var visible by remember { mutableStateOf(false) }
        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            label = { Text(text = label) },
            singleLine = true,
            isError = isError,
            supportingText = supportingText?.let { { Text(text = it) } },
            visualTransformation = if (visible) VisualTransformation.None else PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
            trailingIcon = {
                IconButton(onClick = { visible = !visible }) {
                    Icon(
                        imageVector = if (visible) {
                            MaterialSymbols.Rounded.VisibilityOff
                        } else {
                            MaterialSymbols.Rounded.Visibility
                        },
                        contentDescription = if (visible) {
                            stringResource(MR.strings.sync_settings_password_hide)
                        } else {
                            stringResource(MR.strings.sync_settings_password_show)
                        },
                    )
                }
            },
            modifier = Modifier.fillMaxWidth(),
        )
    }

    @Composable
    private fun getModeGroup(): Preference.PreferenceGroup {
        val context = LocalContext.current
        val graph = remember { context.appGraph }
        val preferences = remember { graph.progressSyncPreferences }
        val komgaPreferences = remember { graph.komgaPreferences }
        val koreaderSummary = stringResource(MR.strings.pref_progress_sync_mode_koreader_summary)
        var showKomgaNotice by remember { mutableStateOf(false) }

        if (showKomgaNotice) {
            KomgaKoreaderNotice(
                onAnswer = { allow, hideNotice ->
                    komgaPreferences.koreaderDownloads.set(allow)
                    if (hideNotice) komgaPreferences.koreaderNoticeHidden.set(true)
                    showKomgaNotice = false
                },
                onDismissRequest = { showKomgaNotice = false },
            )
        }

        return Preference.PreferenceGroup(
            title = stringResource(MR.strings.pref_progress_sync),
            preferenceItems = listOf(
                Preference.PreferenceItem.ListPreference(
                    preference = preferences.mode,
                    entries = mapOf(
                        ProgressSyncMode.SOURCE to stringResource(MR.strings.pref_progress_sync_mode_source),
                        ProgressSyncMode.KOREADER to stringResource(MR.strings.pref_progress_sync_mode_koreader),
                    ),
                    title = stringResource(MR.strings.pref_progress_sync_mode),
                    subtitleProvider = { value, entries ->
                        if (value == ProgressSyncMode.KOREADER) koreaderSummary else entries[value]
                    },
                    onValueChanged = { mode ->
                        // Komga books can only be matched with KOReader by downloading them, so ask first.
                        if (mode == ProgressSyncMode.KOREADER &&
                            preferences.mode.get() != ProgressSyncMode.KOREADER &&
                            komgaPreferences.isConfigured() &&
                            !komgaPreferences.koreaderNoticeHidden.get()
                        ) {
                            showKomgaNotice = true
                        }
                        true
                    },
                ),
            ),
        )
    }

    /**
     * Explains that matching Komga books with KOReader means downloading them, and asks whether
     * to. [onAnswer] gets the choice and whether to stop asking.
     */
    @Composable
    private fun KomgaKoreaderNotice(
        onAnswer: (allow: Boolean, hideNotice: Boolean) -> Unit,
        onDismissRequest: () -> Unit,
    ) {
        var hideNotice by remember { mutableStateOf(false) }
        AlertDialog(
            onDismissRequest = onDismissRequest,
            title = { Text(text = stringResource(MR.strings.komga_koreader_notice_title)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(MaterialTheme.padding.small)) {
                    Text(text = stringResource(MR.strings.komga_koreader_notice_text))
                    // The whole row ticks the box, not only the box itself.
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .toggleable(value = hideNotice, role = Role.Checkbox, onValueChange = { hideNotice = it }),
                    ) {
                        Checkbox(checked = hideNotice, onCheckedChange = null)
                        Text(text = stringResource(MR.strings.komga_koreader_notice_hide))
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { onAnswer(true, hideNotice) }) {
                    Text(text = stringResource(MR.strings.komga_koreader_notice_allow))
                }
            },
            dismissButton = {
                TextButton(onClick = { onAnswer(false, hideNotice) }) {
                    Text(text = stringResource(MR.strings.komga_koreader_notice_deny))
                }
            },
        )
    }
}

/**
 * A server's section of [SettingsSyncScreen], folded to its [logo], [title] and connection status
 * (the item titled "Connection") until opened. It ends with Delete, which asks before calling
 * [onDelete] to erase the section's settings.
 */
@Composable
internal fun serverGroup(
    title: String,
    @DrawableRes logo: Int,
    items: List<Preference.PreferenceItem<out Any, out Any>>,
    onDelete: () -> Unit,
): Preference.PreferenceGroup {
    val connectionTitle = stringResource(MR.strings.pref_kavita_connection)
    val connection = items.firstOrNull { it.title == connectionTitle } as? Preference.PreferenceItem.TextPreference
    var confirmDelete by remember { mutableStateOf(false) }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text(text = stringResource(MR.strings.pref_server_delete_title, title)) },
            text = { Text(text = stringResource(MR.strings.pref_server_delete_text, title)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        onDelete()
                        confirmDelete = false
                    },
                ) {
                    Text(text = stringResource(MR.strings.action_delete))
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmDelete = false }) {
                    Text(text = stringResource(MR.strings.action_cancel))
                }
            },
        )
    }

    return Preference.PreferenceGroup(
        title = title,
        preferenceItems = items + Preference.PreferenceItem.TextPreference(
            title = stringResource(MR.strings.action_delete),
            subtitle = stringResource(MR.strings.pref_server_delete_summary, title),
            onClick = { confirmDelete = true },
        ),
        collapsible = true,
        icon = painterResource(logo),
        summary = connection?.subtitle,
        summaryWidget = connection?.widget,
    )
}
