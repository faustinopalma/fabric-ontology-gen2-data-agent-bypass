import importlib.util
import unittest
from pathlib import Path


spec = importlib.util.spec_from_file_location("lab_mcp", Path(__file__).resolve().parents[1] / "scripts/Test-LabMcp.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AnswerAssessmentTests(unittest.TestCase):
    def result(self, text, is_error=False):
        return {"content": [{"type": "text", "text": text}], "is_error": is_error}

    def test_false_error_flag_does_not_mask_service_failure(self):
        self.assertEqual(module.assess_answer(3, self.result("Something went wrong while loading the ontology definition. Please try again.")), "ServiceError")

    def test_machine_ids_must_match_exactly(self):
        self.assertEqual(module.assess_answer(["M01", "M03"], self.result("M03, M01")), "AnswerTextMatchesOracle")
        self.assertEqual(module.assess_answer(["M01", "M03"], self.result("M01, M02, M03")), "NeedsReview")

    def test_numeric_answers(self):
        self.assertEqual(module.assess_answer(3, self.result("There are 3 actionable anomalies.")), "AnswerTextMatchesOracle")
        self.assertEqual(module.assess_answer(55, self.result("**55 minutes**")), "AnswerTextMatchesOracle")
        self.assertEqual(module.assess_answer(92, self.result("**92 minutes**")), "AnswerTextMatchesOracle")
        self.assertEqual(module.assess_answer(55, self.result("**92 minutes**")), "NeedsReview")
        self.assertEqual(module.assess_answer(3, self.result("There are 6 anomalies; 3 were expected.")), "NeedsReview")

    def test_empty_and_explicit_errors(self):
        self.assertEqual(module.assess_answer(3, self.result("")), "NeedsReview")
        self.assertEqual(module.assess_answer(3, self.result("3", True)), "ServiceError")


if __name__ == "__main__":
    unittest.main()