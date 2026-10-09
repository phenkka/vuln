#!/usr/bin/env python3
import hashlib
import json
import os
import ssl
import sys
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

REPORTS = {
    "gitleaks-report.json":       ("gitleaks", "gitleaks",        "secrets"),
    "dt-findings-backend.json":       ("dependency-track", "dt-sca", "sca"),
    "dt-findings-frontend.json":      ("dependency-track", "dt-sca", "sca"),
    "dt-findings-frontend-deps.json": ("dependency-track", "dt-sca", "sca"),
    "trivy-config-backend.json":  ("trivy",    "trivy-container", "config"),
    "trivy-config-frontend.json": ("trivy",    "trivy-container", "config"),
    "semgrep-report.json":        ("semgrep",  "semgrep",         "sast"),
    "zap-baseline-frontend.json": ("zap",      "zap-scan",        "dast"),
    "zap-full-backend.json":      ("zap",      "zap-scan",        "dast"),
}

SEMGREP_SEVERITY = {"ERROR": "high", "WARNING": "medium", "INFO": "low"}
ZAP_SEVERITY = {"3": "high", "2": "medium", "1": "low", "0": "info"}
DT_SEVERITY = {"CRITICAL": "critical", "HIGH": "high", "MEDIUM": "medium", "LOW": "low", "INFO": "info"}

def finding(rule_id, title, severity, location, key):
    return {"rule_id": rule_id, "title": title, "severity": severity, "location": location, "key": key}

def parse_gitleaks(data):
    for leak in data or []:
        yield finding(leak["RuleID"], leak["Description"], "high", f'{leak["File"]}:{leak["StartLine"]}', leak["Fingerprint"])

def parse_semgrep(data):
    for r in data.get("results", []):
        location = f'{r["path"]}:{r["start"]["line"]}'
        yield finding(r["check_id"], r["extra"]["message"][:200], SEMGREP_SEVERITY.get(r["extra"]["severity"], "info"), location, f'{r["check_id"]}|{location}')

def parse_trivy(data):
    # Target у образа содержит digest, он меняется каждую сборку, поэтому в key
    # берём тип (debian, pip, npm) — иначе все находки образа каждый раз новые
    for res in data.get("Results", []):
        kind = res.get("Type", "")
        for v in res.get("Vulnerabilities") or []:
            pkg = v["PkgName"]
            yield finding(v["VulnerabilityID"], v.get("Title") or pkg, v["Severity"].lower(), f'{pkg}@{v["InstalledVersion"]} ({kind})', f'{v["VulnerabilityID"]}|{kind}|{pkg}')
        for m in res.get("Misconfigurations") or []:
            if m.get("Status") == "PASS":
                continue
            yield finding(m["ID"], m["Title"], m["Severity"].lower(), res["Target"], f'{m["ID"]}|{res["Target"]}')

def parse_zap(data):
    for site in data.get("site", []):
        for a in site.get("alerts", []):
            instances = a.get("instances") or [{}]
            path = urlparse(instances[0].get("uri", "")).path or "/"
            yield finding(a.get("alertRef") or a["pluginid"], a["alert"],
                          ZAP_SEVERITY.get(str(a["riskcode"]), "info"), f'{path} (x{a.get("count", len(instances))})', a.get("alertRef") or a["pluginid"])

def parse_dtrack(data):
    # Находки Dependency-Track, в key пакет без версии - обновили пакет, а уязвимость осталась — та же находка
    for x in data or []:
        v, c = x["vulnerability"], x["component"]
        title = v.get("title") or (v.get("description") or "").split("\n")[0][:200] or v["vulnId"]
        package = c.get("purl", "").split("@")[0] or c["name"]
        yield finding(v["vulnId"], title, DT_SEVERITY.get(v["severity"], "info"), f'{c["name"]}@{c.get("version", "")}', f'{v["vulnId"]}|{package}')

PARSERS = {"gitleaks": parse_gitleaks, "semgrep": parse_semgrep,
           "trivy": parse_trivy, "zap": parse_zap, "dependency-track": parse_dtrack}

def collect_findings(report_dir, run):
    docs = []
    for name, (tool, job_name, category) in REPORTS.items():
        path = Path(report_dir) / name
        if not path.exists():
            # Джоба упала раньше, чем написала отчёт — это видно в логе, но не ломает остальное
            print(f"WARNING: {name} not found, skipping")
            continue
        for f in PARSERS[tool](json.loads(path.read_text() or "null")):
            fingerprint = hashlib.sha256(f'{name}|{f.pop("key")}'.encode()).hexdigest()[:20]
            docs.append({**run, **f, "tool": tool, "job_name": job_name, "category": category, "source": name, "fingerprint": fingerprint})
    return docs

def job_events(jobs, run, skip_job_id=None):
    events = []
    for j in jobs:
        if j["id"] == skip_job_id:
            continue
        events.append({
            "@timestamp": j.get("finished_at") or j.get("started_at") or j["created_at"],
            "project": run["project"], "pipeline_id": run["pipeline_id"],
            "job_id": j["id"], "job_name": j["name"], "stage": j["stage"],
            "status": j["status"], "commit_sha": j["commit"]["id"], "ref": j["ref"],
            "duration_s": j.get("duration"), "queued_s": j.get("queued_duration"),
            "allow_failure": j.get("allow_failure", False),
            "failure_reason": j.get("failure_reason"),
        })
    return events

def gitlab_jobs():
    ctx = ssl.create_default_context(cafile=os.environ.get("CI_SERVER_TLS_CA_FILE"))
    ctx.verify_flags &= ~ssl.VERIFY_X509_STRICT
    url = (f'{os.environ["CI_API_V4_URL"]}/projects/{os.environ["CI_PROJECT_ID"]}' f'/pipelines/{os.environ["CI_PIPELINE_ID"]}/jobs?per_page=100&include_retried=true')
    req = urllib.request.Request(url, headers={"JOB-TOKEN": os.environ["CI_JOB_TOKEN"]})
    with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:  # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected
        return json.load(resp)

def bulk(opensearch_url, index, docs, make_id):
    if not docs:
        return
    lines = []
    for d in docs:
        lines.append(json.dumps({"index": {"_index": index, "_id": make_id(d)}}))
        lines.append(json.dumps(d))
    req = urllib.request.Request(f"{opensearch_url}/_bulk?refresh=true", data=("\n".join(lines) + "\n").encode(), headers={"Content-Type": "application/x-ndjson"})
    with urllib.request.urlopen(req, timeout=60) as resp:  # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected
        result = json.load(resp)
    if result.get("errors"):
        failed = [i["index"]["error"] for i in result["items"] if "error" in i["index"]]
        raise RuntimeError(f"{len(failed)} documents rejected by {index}, first: {failed[0]}")
    print(f"{index}: {len(docs)} documents sent")

def main():
    env = os.environ
    run = {
        "@timestamp": env["CI_PIPELINE_CREATED_AT"],
        "project": env["CI_PROJECT_PATH"],
        "pipeline_id": int(env["CI_PIPELINE_ID"]),
        "commit_sha": env["CI_COMMIT_SHA"],
        "ref": env["CI_COMMIT_REF_NAME"],
    }

    findings = collect_findings(env.get("REPORT_DIR", "."), run)

    summary = {}
    for f in findings:
        summary.setdefault(f["tool"], {}).setdefault(f["severity"], 0)
        summary[f["tool"]][f["severity"]] += 1
    for tool, counts in sorted(summary.items()):
        print(f"{tool:10} {counts}")

    events = job_events(gitlab_jobs(), run, skip_job_id=int(env["CI_JOB_ID"]))

    bulk(env["OPENSEARCH_URL"], "findings", findings, lambda d: f'{d["pipeline_id"]}-{d["fingerprint"]}')
    bulk(env["OPENSEARCH_URL"], "pipeline-events", events, lambda d: str(d["job_id"]))

if __name__ == "__main__":
    try:
        main()
    except Exception as e:  
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)