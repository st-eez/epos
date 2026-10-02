import Epos

#if DEBUG
if SignedAnalyzerPreparationEvalHost.isRequested {
    await SignedAnalyzerPreparationEvalHost.runAndExit()
}
if SignedApplePresetEvalHost.isRequested {
    await SignedApplePresetEvalHost.runAndExit()
}
#endif

EposApp.main()
