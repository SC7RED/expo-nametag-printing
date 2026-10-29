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
    /// with no questions: Detect, Plan, Apply, Quit. A double-click shows a small progress window
    /// with no buttons; /quiet shows nothing at all. If setup fails, one error box says so
    /// (not with /quiet).
    /// </summary>
    public sealed class SilentBootstrapperApplication : BootstrapperApplication
    {
        // Must match the ExePackage Id and the Variable name in Bundle.wxs.
        private const string DymoPackageId = "DYMO";
        private const string DymoPreinstalledVariable = "DymoPreinstalled";
        private const string DymoVersionVariable = "DymoLabelVersion";

        // The laptop settings file that must sit next to ExpoNametagSetup.exe (see Package.wxs).
        private const string SettingsFileName = "ExpoNametag.env";

        private const int ErrorFileNotFound = 2;
        private const int ErrorCancelled = 1223; // the user said No to UAC
        private const int ErrorSuccessRebootRequired = 3010;

        private readonly ManualResetEvent windowReady = new ManualResetEvent(false);
        private IBootstrapperCommand command;
        private LaunchAction action;
        private SetupWindow window;
        private IntPtr windowHandle;
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
            this.windowReady.WaitOne();

            if (this.action == LaunchAction.Help || this.action == LaunchAction.Unknown)
            {
                this.Log("nothing to do for action {0}", this.action);
                this.Finish(0);
                return;
            }

            this.engine.Detect(this.windowHandle);
        }

        protected override void Run()
        {
            Application.EnableVisualStyles(); // the moving progress bar needs these
            using (this.window = new SetupWindow(visible: !this.IsQuiet))
            {
                this.windowHandle = this.window.Handle;
                this.windowReady.Set();
                Application.Run(this.window); // returns when Finish() closes the window
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

                // Record once, on this bundle's first install, whether any DYMO version was already
                // installed (Bundle.wxs's search sets DymoLabelVersion to 0.0.0.0 when it finds none).
                // Later runs keep the persisted value; re-detecting then would see the DYMO we installed.
                bool dymoFound = this.engine.ContainsVariable(DymoVersionVariable)
                    && this.engine.GetVariableVersion(DymoVersionVariable) != "0.0.0.0";
                long preinstalled = this.upgradedBundleDymoPreinstalled ?? (dymoFound ? 1 : 0);
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

            // The handle parents the UAC prompt; see SetupWindow.
            this.engine.Apply(this.windowHandle);
        }

        protected override void OnCacheAcquireBegin(CacheAcquireBeginEventArgs args)
        {
            base.OnCacheAcquireBegin(args);
            if (args.PackageOrContainerId == DymoPackageId)
            {
                this.window.SetStatus("Getting DYMO Label Software ready...");
            }
        }

        protected override void OnExecutePackageBegin(ExecutePackageBeginEventArgs args)
        {
            base.OnExecutePackageBegin(args);
            bool dymo = args.PackageId == DymoPackageId;
            string name = dymo ? "DYMO Label Software" : "Expo Nametag Printing";
            this.window.SetStatus(this.action == LaunchAction.Uninstall
                ? "Removing " + name + "..."
                : "Installing " + name + "..." + (dymo ? "\nThis takes a few minutes." : ""));
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

        // /quiet (None) and running inside another installer (Embedded) show nothing.
        private bool IsQuiet => this.command.Display == Display.None || this.command.Display == Display.Embedded;

        private void Finish(int status, string errorMessage = null)
        {
            // Burn's exit code should be a plain Win32 error (e.g. 1223 when UAC is declined), not an HRESULT.
            if ((status & 0xFFFF0000) == unchecked((int)0x80070000))
            {
                status &= 0xFFFF;
            }

            bool failed = status != 0 && status != ErrorSuccessRebootRequired && status != ErrorCancelled;
            if (failed && !this.IsQuiet)
            {
                string message = errorMessage ?? string.Format(
                    "Setup failed (error {0}).\n\nDetails are in the log file:\n{1}",
                    status, this.engine.GetVariableString("WixBundleLog"));
                // DefaultDesktopOnly keeps the box in front of every window, ours included.
                MessageBox.Show(message, "Expo Nametag Printing setup", MessageBoxButtons.OK,
                    MessageBoxIcon.Error, MessageBoxDefaultButton.Button1, MessageBoxOptions.DefaultDesktopOnly);
            }

            string doneText = null; // null: close right away
            if (status == 0 && this.action == LaunchAction.Install)
            {
                doneText = "Done. Open Expo Nametag Printing from the desktop.";
            }
            else if (status == 0 && this.action == LaunchAction.Uninstall)
            {
                doneText = "Done. Expo Nametag Printing was removed.";
            }
            else if (status == ErrorSuccessRebootRequired)
            {
                doneText = "Done. Restart the laptop before using the printer.";
            }

            this.result = status;
            this.window.CloseAfter(doneText);
        }

        private static bool Succeeded(int hresult) => hresult >= 0;

        private void Log(string format, params object[] args)
        {
            this.engine.Log(LogLevel.Standard, "SilentBA: " + string.Format(format, args));
        }

        /// <summary>
        /// The setup window: one line of status and a moving progress bar, no buttons. (DYMO's installer
        /// reports no progress, so the bar shows that setup is working, not how far along it is.)
        /// With /quiet it is a borderless, fully transparent 1x1 window instead, never in the taskbar.
        /// Either way it is shown from startup, while the process still has foreground rights, because Burn
        /// passes its handle to the UAC prompt as the parent, and Windows only brings that prompt to the
        /// foreground when the parent is the foreground window.
        /// </summary>
        private sealed class SetupWindow : Form
        {
            private readonly bool visible;
            private readonly Label status = new Label();
            private bool closing;

            public SetupWindow(bool visible)
            {
                this.visible = visible;
                this.Text = "Expo Nametag Printing Setup";
                if (!visible)
                {
                    this.FormBorderStyle = FormBorderStyle.None;
                    this.ShowInTaskbar = false;
                    this.StartPosition = FormStartPosition.Manual;
                    this.Location = new Point(-2000, -2000);
                    this.Size = new Size(1, 1);
                    this.Opacity = 0;
                    return;
                }

                this.FormBorderStyle = FormBorderStyle.FixedDialog;
                this.ControlBox = false; // no close button: setup closes the window itself
                this.StartPosition = FormStartPosition.CenterScreen;
                this.Font = SystemFonts.MessageBoxFont;
                this.ClientSize = new Size(440, 120);

                this.status.SetBounds(20, 20, 400, 44);
                this.status.Text = "Getting ready...";
                var bar = new ProgressBar { Style = ProgressBarStyle.Marquee, MarqueeAnimationSpeed = 30 };
                bar.SetBounds(20, 74, 400, 22);
                this.Controls.Add(this.status);
                this.Controls.Add(bar);
            }

            // Safe to call from any thread.
            public void SetStatus(string text)
            {
                this.BeginInvoke(new Action(() => this.status.Text = text));
            }

            // Shows doneText for 3 seconds and closes; with no text (or when invisible), closes now.
            public void CloseAfter(string doneText)
            {
                this.BeginInvoke(new Action(() =>
                {
                    this.closing = true;
                    if (!this.visible || doneText == null)
                    {
                        this.Close();
                        return;
                    }

                    this.status.Text = doneText;
                    var timer = new System.Windows.Forms.Timer { Interval = 3000 };
                    timer.Tick += (sender, e) => { timer.Stop(); this.Close(); };
                    timer.Start();
                }));
            }

            // Alt+F4 must not close the window mid-install: Run() would then quit the engine.
            protected override void OnFormClosing(FormClosingEventArgs e)
            {
                e.Cancel = !this.closing;
                base.OnFormClosing(e);
            }

            // Keep the invisible window out of Alt+Tab.
            protected override CreateParams CreateParams
            {
                get
                {
                    const int WS_EX_TOOLWINDOW = 0x80;
                    CreateParams cp = base.CreateParams;
                    if (!this.visible)
                    {
                        cp.ExStyle |= WS_EX_TOOLWINDOW;
                    }

                    return cp;
                }
            }
        }
    }
}
