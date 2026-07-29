import Epos

#if DEBUG
if SignedApplePresetEvalHost.isRequested {
    await SignedApplePresetEvalHost.runAndExit()
}
#endif

EposApp.main()
