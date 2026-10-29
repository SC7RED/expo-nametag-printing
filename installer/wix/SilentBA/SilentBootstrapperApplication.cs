namespace ExpoNametag.SilentBA
{
    using System;
    using System.Drawing;
    using System.IO;
    using System.Threading;
    using System.Windows.Forms;
    using WixToolset.BootstrapperApplicationApi;

    /// <summary>
    /// Runs the bundle's command (install by default, uninstall from Settings > Apps or /uninstall)
    /// with no UI: Detect, Plan, Apply, Quit. The only thing ever shown is one error box if setup
    /// fails, and not even that with /quiet.
    /// </summary>
    public sealed class SilentBootstrapperApplication : BootstrapperApplication
    {
        // Must match the ExePackage Id and the Variable name in Bundle.wxs.
        private const string DymoPackageId = "DYMO";
        private const string DymoPreinstalledVariable = "DymoPreinstalled";

        // The laptop settings file that must sit next to ExpoNametagSetup.exe (see Package.wxs).
        private const string SettingsFileName = "ExpoNametag.env";

        private const int ErrorFileNotFound = 2;
        private const int ErrorCancelled = 1223; // the user said No to UAC
        private const int ErrorSuccessRebootRequired = 3010;

        private readonly ManualResetEvent ownerWindowReady = new ManualResetEvent(false);
        private IBootstrapperCommand command;
        private LaunchAction action;
        private OwnerWindow ownerWindow;
        private IntPtr ownerHandle;
        private bool dymoPresent;
        private long? upgradedBundleDymoPreinstalled;
        private int result;

        protected override void OnCreate(CreateEventArgs args)
        {
            base.OnCreate(args);
            this.command = args.Command;
        }

        protected override void OnStartup(StartupEventArgs args)
        {
            this.action = this.command.Action;
            this.Log("action={0}, display={1}, relation={2}", this.action, this.command.Display, this.command.Relation);

            base.OnStartup(args); // starts Run() on its own STA thread
            this.ownerWindowReady.WaitOne();

            if (this.action == LaunchAction.Help || this.action == LaunchAction.Unknown)
            {
                this.Log("nothing to do for action {0}", this.action);
                this.Finish(0);
                return;
            }

            this.engine.Detect(this.ownerHandle);
        }

        protected override void Run()
        {
            using (this.ownerWindow = new OwnerWindow())
            {
                this.ownerHandle = this.ownerWindow.Handle;
                this.ownerWindowReady.Set();
                Application.Run(this.ownerWindow); // returns when Finish() closes the window
            }

            this.engine.Quit(this.result);
        }

        protected override void OnDetectRelatedBundle(DetectRelatedBundleEventArgs args)
        {
            base.OnDetectRelatedBundle(args);

            // An older version of this bundle is being upgraded: carry its answer forward,
            // because by now DYMO may be present only because that older bundle installed it.
            if (args.RelationType == RelationType.Upgrade && this.action == LaunchAction.Install)
            {
                try
                {
                    string value = this.engine.GetRelatedBundleVariable(args.ProductCode, DymoPreinstalledVariable);
                    if (long.TryParse(value, out long parsed))
                    {
                        this.upgradedBundleDymoPreinstalled = parsed;
                    }
                }
                catch (Exception e)
                {
                    this.Log("could not read {0} from related bundle {1}: {2}", DymoPreinstalledVariable, args.ProductCode, e.Message);
                }
            }
        }

        protected override void OnDetectPackageComplete(DetectPackageCompleteEventArgs args)
        {
            base.OnDetectPackageComplete(args);

            if (args.PackageId == DymoPackageId)
            {
                this.dymoPresent = args.State == PackageState.Present;
            }
        }

        protected override void OnDetectComplete(DetectCompleteEventArgs args)
        {
            base.OnDetectComplete(args);

            if (!Succeeded(args.Status))
            {
                this.Log("detect failed: 0x{0:X8}", args.Status);
                this.Finish(args.Status);
                return;
            }

            if (this.action == LaunchAction.Install && this.engine.GetVariableNumeric("WixBundleInstalled") == 0)
            {
                // A first install needs the laptop settings, or the app couldn't look anyone up.
                string folder = this.engine.GetVariableString("WixBundleOriginalSourceFolder");
                if (!File.Exists(Path.Combine(folder, SettingsFileName)))
                {
                    this.Log("{0} not found in {1}", SettingsFileName, folder);
                    this.Finish(ErrorFileNotFound, SettingsFileName + " was not found.\n\n" +
                        "Put it in the same folder as ExpoNametagSetup.exe and run the installer again.");
                    return;
                }

                // Record once, on this bundle's first install, whether DYMO was already installed.
                // Later runs keep the persisted value; re-detecting then would see the DYMO we installed.
                long preinstalled = this.upgradedBundleDymoPreinstalled ?? (this.dymoPresent ? 1 : 0);
                this.engine.SetVariableNumeric(DymoPreinstalledVariable, preinstalled);
                this.Log("{0}={1}", DymoPreinstalledVariable, preinstalled);
            }

            this.engine.Plan(this.action);
        }

        protected override void OnPlanPackageBegin(PlanPackageBeginEventArgs args)
        {
            base.OnPlanPackageBegin(args);

            // Never remove a DYMO install that was there before us. Also keep it when a newer
            // version of this bundle is removing this one as part of an upgrade.
            if (args.PackageId == DymoPackageId && this.action == LaunchAction.Uninstall)
            {
                bool preinstalled = this.engine.GetVariableNumeric(DymoPreinstalledVariable) == 1;
                bool upgrading = this.command.Relation == RelationType.Upgrade;
                if (preinstalled || upgrading)
                {
                    args.State = RequestState.None;
                    this.Log("keeping DYMO (preinstalled={0}, upgrade={1})", preinstalled, upgrading);
                }
            }
        }

        protected override void OnPlanComplete(PlanCompleteEventArgs args)
        {
            base.OnPlanComplete(args);

            if (!Succeeded(args.Status))
            {
                this.Log("plan failed: 0x{0:X8}", args.Status);
                this.Finish(args.Status);
                return;
            }

            // The handle parents the UAC prompt; see OwnerWindow.
            this.engine.Apply(this.ownerHandle);
        }

        protected override void OnApplyComplete(ApplyCompleteEventArgs args)
        {
            base.OnApplyComplete(args);

            // Never reboot; report "success, reboot required" (3010) instead, like msiexec does.
            args.Action = BOOTSTRAPPER_APPLYCOMPLETE_ACTION.None;
            int code = args.Status;
            if (Succeeded(code) && args.Restart != ApplyRestart.None)
            {
                code = ErrorSuccessRebootRequired;
            }

            this.Log("apply complete: status=0x{0:X8}, restart={1}, exit code={2}", args.Status, args.Restart, code);
            this.Finish(code);
        }

        private void Finish(int status, string errorMessage = null)
        {
            // Burn's exit code should be a plain Win32 error (e.g. 1223 when UAC is declined), not an HRESULT.
            if ((status & 0xFFFF0000) == unchecked((int)0x80070000))
            {
                status &= 0xFFFF;
            }

            bool failed = status != 0 && status != ErrorSuccessRebootRequired && status != ErrorCancelled;
            bool quiet = this.command.Display == Display.None || this.command.Display == Display.Embedded;
            if (failed && !quiet)
            {
                string message = errorMessage ?? string.Format(
                    "Setup failed (error {0}).\n\nDetails are in the log file:\n{1}",
                    status, this.engine.GetVariableString("WixBundleLog"));
                // DefaultDesktopOnly keeps the box in front even though our own window is invisible.
                MessageBox.Show(message, "Expo Nametag Printing setup", MessageBoxButtons.OK,
                    MessageBoxIcon.Error, MessageBoxDefaultButton.Button1, MessageBoxOptions.DefaultDesktopOnly);
            }

            this.result = status;
            this.ownerWindow.BeginInvoke(new Action(this.ownerWindow.Close));
        }

        private static bool Succeeded(int hresult) => hresult >= 0;

        private void Log(string format, params object[] args)
        {
            this.engine.Log(LogLevel.Standard, "SilentBA: " + string.Format(format, args));
        }

        /// <summary>
        /// A borderless, fully transparent 1x1 window that is never in the taskbar.
        /// Burn passes its handle to the UAC prompt as the parent. Windows only brings that prompt to
        /// the foreground when the parent is the foreground window; a hidden window can't be, so this one
        /// is shown (but invisible) from startup, while the process still has foreground rights.
        /// </summary>
        private sealed class OwnerWindow : Form
        {
            public OwnerWindow()
            {
                this.Text = "Expo Nametag Printing Setup";
                this.FormBorderStyle = FormBorderStyle.None;
                this.ShowInTaskbar = false;
                this.StartPosition = FormStartPosition.Manual;
                this.Location = new Point(-2000, -2000);
                this.Size = new Size(1, 1);
                this.Opacity = 0;
            }

            // Keep it out of Alt+Tab.
            protected override CreateParams CreateParams
            {
                get
                {
                    const int WS_EX_TOOLWINDOW = 0x80;
                    CreateParams cp = base.CreateParams;
                    cp.ExStyle |= WS_EX_TOOLWINDOW;
                    return cp;
                }
            }
        }
    }
}
