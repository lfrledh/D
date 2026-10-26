"""Bounded source guard for the visual bypasses repaired in D-UI-CONSOLIDATED-01.

This is not a whole-UI style validator or native appearance test. System menus,
real sidebar plates, settings material samples and plain selection rows remain
outside this zero-bypass baseline. New exceptions require review at their real
presentation path; do not broaden the scope by replacing every native style.
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
VIEWS = pathlib.Path("Packages/UI/Sources/UI/Views")
ROLE_PATHS = (
    VIEWS / "Workflow/WorkflowCanvasView.swift",
    VIEWS / "Workflow/WorkflowWorkspaceRunPlan.swift",
    VIEWS / "Workflow/WorkflowDockPresentation.swift",
)
LAYOUT_PATHS = (
    VIEWS / "Workflow/SharedLibraryBrowser.swift",
    VIEWS / "Workflow/SharedLibraryQueryEditor.swift",
    VIEWS / "Chat/ChatWorkbenchView.swift",
)
ROLE_BYPASS = re.compile(
    r"\.buttonStyle\s*\(\s*\.bordered(?:Prominent)?\s*\)"
    r"|\.textFieldStyle\s*\(\s*\.roundedBorder\s*\)"
)
RECTANGULAR_PARENT = re.compile(r"\.workbenchPanel\s*\(\s*cornerRadius\s*:\s*0(?:\.0+)?\s*\)")


def violations(path, source):
    checks = []
    if path in ROLE_PATHS:
        checks.append((ROLE_BYPASS, "inner system style overrides the shared role"))
    if path in LAYOUT_PATHS:
        checks.append((RECTANGULAR_PARENT, "transparent layout parent paints a rectangular plate"))
    return [f"{path}:{source.count(chr(10), 0, hit.start()) + 1}: {reason}"
            for pattern, reason in checks for hit in pattern.finditer(source)]


class UIVisualBoundaryTests(unittest.TestCase):
    def test_repaired_product_paths_keep_zero_bypass_baseline(self):
        found = []
        for path in (*ROLE_PATHS, *LAYOUT_PATHS):
            found.extend(violations(path, (ROOT / path).read_text(encoding="utf-8")))
        self.assertEqual([], found, "\n".join(found))

    def test_old_overrides_and_parent_plate_are_detected(self):
        old_roles = "retained(body.buttonStyle(.bordered).textFieldStyle(.roundedBorder))\nbutton.buttonStyle(.borderedProminent)"
        self.assertEqual(3, len(violations(ROLE_PATHS[0], old_roles)))
        old_parent = "stack.workbenchPanel(cornerRadius: 0).workbenchSurface(.scrollEdge)"
        self.assertEqual(1, len(violations(LAYOUT_PATHS[0], old_parent)))

    def test_shared_roles_and_deliberate_other_surfaces_remain_allowed(self):
        shared = "body.buttonStyle(WorkbenchGlassButtonStyle()).textFieldStyle(WorkbenchGlassTextFieldStyle())\nbutton.buttonStyle(WorkbenchPrimaryButtonStyle())\nselection.buttonStyle(.plain)"
        self.assertEqual([], violations(ROLE_PATHS[0], shared))
        self.assertEqual([], violations(LAYOUT_PATHS[0], "input.workbenchInputSurface()"))
        self.assertEqual([], violations(VIEWS / "Chat/ChatDisplayPreferencesPanel.swift", "sample.workbenchPanel(cornerRadius: 0)"))


if __name__ == "__main__":
    unittest.main()
