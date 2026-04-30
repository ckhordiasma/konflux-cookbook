#!/usr/bin/env python3

import argparse
import os
import subprocess
import sys

import yaml


def parse_args():
    parser = argparse.ArgumentParser(
        description="Compare two Conforma (Enterprise Contract) policies against the same snapshot."
    )
    parser.add_argument("--application", default=os.environ.get("APPLICATION", "rhoai-v2-25"),
                        help="Application name (default: $APPLICATION or rhoai-v2-25)")
    parser.add_argument("--policy-a", default=os.environ.get("POLICY_A"),
                        help="First policy file to compare (default: $POLICY_A)")
    parser.add_argument("--policy-b", default=os.environ.get("POLICY_B"),
                        help="Second policy file to compare (default: $POLICY_B)")
    parser.add_argument("--snapshot", default=os.environ.get("SNAPSHOT", ""),
                        help="Snapshot to validate (default: $SNAPSHOT)")
    parser.add_argument("--workers", default=os.environ.get("WORKERS", "25"),
                        help="Number of parallel workers (default: $WORKERS or 25)")
    parser.add_argument("--pubkey", default=os.environ.get("PUBKEY", ""),
                        help="Public key for signature verification (default: $PUBKEY)")
    parser.add_argument("--verbose", action="store_true", default=bool(os.environ.get("VERBOSE")),
                        help="Enable verbose output (default: $VERBOSE)")
    return parser.parse_args()


def start_conforma(application, policy_file, results_file, env_passthrough, stderr_file):
    env = {
        **os.environ,
        "APPLICATION": application,
        "POLICY_FILE": policy_file,
        "RESULTS_FILE": results_file,
    }
    for key in ("SNAPSHOT", "WORKERS", "VERBOSE", "PUBKEY"):
        val = env_passthrough.get(key)
        if val:
            env[key] = val

    stderr_fh = open(stderr_file, "w")
    proc = subprocess.Popen(["bash", "test-conforma.sh"], env=env, stderr=stderr_fh)
    proc._stderr_fh = stderr_fh
    proc._stderr_file = stderr_file
    return proc


def load_results(path, label):
    try:
        with open(path) as f:
            data = yaml.safe_load(f)
    except FileNotFoundError:
        print(f"ERROR: Results file not found: {path} ({label})")
        sys.exit(1)

    if data is None:
        print(f"ERROR: Results file is empty: {path} ({label})")
        print(f"  The ec command for {label} likely failed. Check output above.")
        sys.exit(1)

    return data


def extract(data):
    components = {}
    for comp in data.get("components", []):
        name = comp.get("name", "unknown")
        warnings = sorted(w.get("msg", "") for w in (comp.get("warnings") or []))
        violations = sorted(v.get("msg", "") for v in (comp.get("violations") or []))
        components[name] = {
            "success": comp.get("success"),
            "warnings": warnings,
            "violations": violations,
        }
    return components


def print_summary(ra, rb, policy_a, policy_b, exit_a, exit_b):
    sa = sum(1 for v in ra.values() if v["success"])
    sb = sum(1 for v in rb.values() if v["success"])
    fa = sum(1 for v in ra.values() if not v["success"])
    fb = sum(1 for v in rb.values() if not v["success"])
    wa = sum(len(v["warnings"]) for v in ra.values())
    wb = sum(len(v["warnings"]) for v in rb.values())
    va = sum(len(v["violations"]) for v in ra.values())
    vb = sum(len(v["violations"]) for v in rb.values())

    print(f"Policy A:    {policy_a} (exit: {exit_a})")
    print(f"Policy B:    {policy_b} (exit: {exit_b})")
    print()
    print(f"              Policy A    Policy B    Delta")
    print(f"Succeeded:    {sa:<11}{sb:<11}{sb - sa:+d}")
    print(f"Failed:       {fa:<11}{fb:<11}{fb - fa:+d}")
    print(f"Warnings:     {wa:<11}{wb:<11}{wb - wa:+d}")
    print(f"Violations:   {va:<11}{vb:<11}{vb - va:+d}")


def print_diffs(ra, rb):
    all_names = sorted(set(list(ra.keys()) + list(rb.keys())))
    has_diff = False

    for name in all_names:
        ca = ra.get(name, {"success": None, "warnings": [], "violations": []})
        cb = rb.get(name, {"success": None, "warnings": [], "violations": []})

        if ca == cb:
            continue

        has_diff = True
        print(f"\n  {name}:")

        if ca["success"] != cb["success"]:
            print(f"    success: {ca['success']} -> {cb['success']}")

        added_w = [w for w in cb["warnings"] if w not in ca["warnings"]]
        removed_w = [w for w in ca["warnings"] if w not in cb["warnings"]]
        for w in removed_w:
            print(f"    - warning: {w[:150]}")
        for w in added_w:
            print(f"    + warning: {w[:150]}")

        added_v = [v for v in cb["violations"] if v not in ca["violations"]]
        removed_v = [v for v in ca["violations"] if v not in cb["violations"]]
        for v in removed_v:
            print(f"    - violation: {v[:150]}")
        for v in added_v:
            print(f"    + violation: {v[:150]}")

    if not has_diff:
        print("No differences in violations or warnings between policies.")


def main():
    args = parse_args()
    application = args.application
    policy_a = args.policy_a
    policy_b = args.policy_b

    if not policy_a or not policy_b:
        print("ERROR: Both --policy-a and --policy-b are required.")
        sys.exit(1)

    if policy_a == policy_b:
        print(f"ERROR: --policy-a and --policy-b are the same: {policy_a}")
        sys.exit(1)

    env_passthrough = {
        "SNAPSHOT": args.snapshot,
        "WORKERS": args.workers,
        "VERBOSE": "1" if args.verbose else "",
        "PUBKEY": args.pubkey,
    }

    results_a = f"ec-report-{application}-policy-a.yaml"
    results_b = f"ec-report-{application}-policy-b.yaml"

    print(f"=== Comparing policies for {application} ===")
    print(f"Policy A: {policy_a}")
    print(f"Policy B: {policy_b}")
    print()

    stderr_a = f"ec-stderr-{application}-policy-a.log"
    stderr_b = f"ec-stderr-{application}-policy-b.log"

    print(f"=== Running both policies in parallel ===")
    proc_a = start_conforma(application, policy_a, results_a, env_passthrough, stderr_a)
    proc_b = start_conforma(application, policy_b, results_b, env_passthrough, stderr_b)

    exit_a = proc_a.wait()
    proc_a._stderr_fh.close()
    exit_b = proc_b.wait()
    proc_b._stderr_fh.close()

    for label, exit_code, stderr_path in [("Policy A", exit_a, stderr_a), ("Policy B", exit_b, stderr_b)]:
        if exit_code != 0:
            print(f"\nWARNING: {label} exited with code {exit_code}")
            with open(stderr_path) as f:
                err = f.read().strip()
            if err:
                print(f"  stderr: {err[:500]}")

    print()
    print("==========================================")
    print("=== Policy Comparison Results ===")
    print("==========================================")
    print(f"Application: {application}")

    ra = extract(load_results(results_a, "Policy A"))
    rb = extract(load_results(results_b, "Policy B"))

    print_summary(ra, rb, policy_a, policy_b, exit_a, exit_b)
    print()
    print("=== Per-Component Differences ===")
    print_diffs(ra, rb)


if __name__ == "__main__":
    main()
