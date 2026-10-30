// Why not REA_GHIDRA_DISABLED_ANALYZERS: REA's own import is not saved, and analyzeHeadless needs
// the same switch to build a project REA can reuse.
import ghidra.app.script.GhidraScript;

public class DisableObjcMessage extends GhidraScript {
    @Override
    public void run() throws Exception {
        setAnalysisOption(currentProgram, "Objective-C Message Analyzer", "false");
    }
}
