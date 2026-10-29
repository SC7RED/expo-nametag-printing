namespace ExpoNametag.SilentBA
{
    using WixToolset.BootstrapperApplicationApi;

    internal static class Program
    {
        private static int Main()
        {
            // Connects to the Burn engine that started this process and pumps its callbacks
            // until the BA calls Engine.Quit. Burn uses the code passed to Quit as Setup.exe's exit code.
            ManagedBootstrapperApplication.Run(new SilentBootstrapperApplication());
            return 0;
        }
    }
}
