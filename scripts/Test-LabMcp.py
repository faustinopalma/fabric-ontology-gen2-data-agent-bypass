import argparse
import asyncio
import json
import os
import re
import time
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

import httpx2
from azure.identity import AzureCliCredential
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client


ROOT = Path(__file__).resolve().parents[1]


def assess_answer(expected, result):
    text = "\n".join(block.get("text", "") for block in result.get("content", []) if block.get("type") == "text")
    if result.get("is_error") or re.search(r"something went wrong|failed to|unable to|please try again", text, re.IGNORECASE):
        return "ServiceError"
    if isinstance(expected, list):
        matched = sorted(set(re.findall(r"\bM\d{2}\b", text))) == sorted(expected)
    else:
        matched = set(re.findall(r"\b\d+(?:\.\d+)?\b", text)) == {str(expected)}
    return "AnswerTextMatchesOracle" if matched else "NeedsReview"


async def probe(options):
    os.environ["AZURE_CONFIG_DIR"] = str(ROOT / ".azure")
    state = json.loads((ROOT / ".local/lab-state.json").read_text(encoding="utf-8-sig"))
    if state["project"] != "fabric-ontology-gen2-lab":
        raise ValueError("Unexpected lab ownership")
    credential = AzureCliCredential(process_timeout=90)
    token = credential.get_token("https://api.fabric.microsoft.com/.default")
    headers = {"Authorization": f"Bearer {token.token}"}
    workspace = state["workspaceId"]
    async with httpx2.AsyncClient(headers=headers, timeout=90) as discovery:
        response = await discovery.get(f"https://api.fabric.microsoft.com/v1/workspaces/{workspace}")
        response.raise_for_status()
        metadata = response.json()
        if metadata.get("capacityId") != state["capacityId"] or metadata.get("description") != "Synthetic isolated reproduction lab: fabric-ontology-gen2-lab.":
            raise ValueError("Workspace ownership mismatch")
        response = await discovery.get(f"https://api.fabric.microsoft.com/v1/workspaces/{workspace}/items")
        response.raise_for_status()
        inventory = response.json()
        if inventory.get("continuationToken"):
            raise ValueError("Complete item inventory required")
    item_type = "Ontology" if options.target == "ontology" else "DataAgent"
    item_name = "MaintenanceNew" if options.target == "ontology" else options.agent
    matches = [item for item in inventory["value"] if item["type"] == item_type and item["displayName"] == item_name]
    if len(matches) != 1 or matches[0].get("description") != "Synthetic isolated reproduction lab: fabric-ontology-gen2-lab.":
        raise ValueError("Expected unique lab-owned target")
    item_id = matches[0]["id"]
    if options.target == "ontology":
        endpoint = f"https://api.fabric.microsoft.com/v1/mcp/dataPlane/workspaces/{workspace}/items/{item_id}/ontologyEndpoint"
    else:
        endpoint = f"https://api.fabric.microsoft.com/v1/mcp/workspaces/{workspace}/dataagents/{item_id}/agent"
    evidence = ROOT / ".local" / f"mcp-{options.target}-{uuid4().hex}.json"
    record = {"startedAtUtc": datetime.now(timezone.utc).isoformat(), "target": options.target, "itemId": item_id, "phase": "Initializing", "calls": []}

    def persist():
        evidence.write_text(json.dumps(record, indent=2, ensure_ascii=True), encoding="utf-8")

    persist()
    try:
        async with httpx2.AsyncClient(headers=headers, timeout=1200) as client:
            async with streamable_http_client(endpoint, http_client=client) as (read_stream, write_stream):
                async with ClientSession(read_stream, write_stream, read_timeout_seconds=1200) as session:
                    await session.initialize()
                    tools = await session.list_tools()
                    record["tools"] = tools.model_dump(mode="json")
                    persist()
                    if tools.next_cursor:
                        raise ValueError("Complete tool inventory required")
                    print(json.dumps(record["tools"], indent=2), flush=True)
                    calls = []
                    if options.suite:
                        candidates = tools.tools if options.target == "agent" else [tool for tool in tools.tools if tool.name == "ask_ontology"]
                        if len(candidates) != 1:
                            raise ValueError("Question suite requires one unambiguous query tool")
                        tool = candidates[0]
                        properties = tool.input_schema.get("properties", {})
                        if len(properties) != 1 or next(iter(properties.values())).get("type") != "string":
                            raise ValueError("Inspect tool schema before providing query arguments")
                        argument = next(iter(properties))
                        fixture = json.loads((ROOT / "fixtures/questions.json").read_text(encoding="utf-8-sig"))
                        calls = [(question["id"], tool.name, {argument: question["question"]}) for question in fixture["questions"]]
                    elif options.tool:
                        if options.tool not in [tool.name for tool in tools.tools]:
                            raise ValueError("Tool not advertised by server")
                        calls = [("probe", options.tool, json.loads(options.arguments))]
                    for question_id, tool_name, arguments in calls:
                        call = {"id": question_id, "tool": tool_name, "arguments": arguments, "phase": "Submitting"}
                        record["calls"].append(call)
                        persist()
                        started = time.monotonic()
                        result = await session.call_tool(tool_name, arguments, read_timeout_seconds=1200)
                        call.update(phase="ResponseReceived", elapsedSeconds=round(time.monotonic() - started, 3), result=result.model_dump(mode="json"))
                        if options.suite:
                            expected = next(question["expected"] for question in fixture["questions"] if question["id"] == question_id)
                            call["assessment"] = assess_answer(expected, call["result"])
                        persist()
                        print(json.dumps(call, indent=2), flush=True)
                    record["phase"] = "Completed"
                    if options.suite:
                        record["answerTextOraclePassed"] = len(record["calls"]) == len(fixture["questions"]) and all(call["assessment"] == "AnswerTextMatchesOracle" for call in record["calls"])
        if options.suite and not record["answerTextOraclePassed"]:
            raise AssertionError("Question suite did not match the expected answers; inspect private evidence.")
    except BaseException as error:
        record.update(phase="Failed", errorType=type(error).__name__, error=str(error))
        raise
    finally:
        persist()
        print(f"Private evidence: {evidence}", flush=True)
        credential.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", choices=["ontology", "agent"], required=True)
    parser.add_argument("--agent", default="MaintenanceGen2")
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("--tool")
    actions.add_argument("--suite", action="store_true")
    parser.add_argument("--arguments", default="{}")
    arguments = parser.parse_args()
    asyncio.run(asyncio.wait_for(probe(arguments), timeout=1200))