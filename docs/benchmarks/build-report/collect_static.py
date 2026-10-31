"""Collects static facts about every native CMake build tree of an Exosuit checkout.

Usage: python -I collect_static.py <checkout root> <out.json>

For each <app>/build/host/native/<package>/cmake* tree: the CMakeCache settings, the try_compile count of its
configure, and every target that compiles code, in the same shape for both generators:

- Visual Studio trees: each real .vcxproj (its Release compile and link settings, source count), the intermediate
  directory (object count and size, first and last object write time) and the cl/link/lib command lines from the
  MSBuild .tlog files.
- Ninja trees: each target's compile edges in build.ninja, the command lines from compile_commands.json, the link
  edge and its flags, the objects on disk and the edge times in .ninja_log (made absolute from the output times
  ninja records).

Also the files next to each package's tree, the Haxe outputs, and the haxeon bootstrap's own Ninja logs.
"""

import json
import os
import re
import sys
from pathlib import Path

SKIP_PROJECTS = {
    "ALL_BUILD", "ZERO_CHECK", "INSTALL", "PACKAGE", "RUN_TESTS", "Continuous", "Experimental", "Nightly",
    "NightlyMemoryCheck", "format", "format-check", "dist", "GENHDR",
}
CACHE_KEYS = [
    "CMAKE_GENERATOR", "CMAKE_GENERATOR_INSTANCE", "CMAKE_BUILD_TYPE", "CMAKE_C_FLAGS", "CMAKE_C_FLAGS_RELEASE",
    "CMAKE_CXX_FLAGS", "CMAKE_CXX_FLAGS_RELEASE", "CMAKE_SHARED_LINKER_FLAGS", "CMAKE_SHARED_LINKER_FLAGS_RELEASE",
    "CMAKE_EXE_LINKER_FLAGS_RELEASE", "CMAKE_MSVC_RUNTIME_LIBRARY", "CMAKE_INTERPROCEDURAL_OPTIMIZATION",
    "CMAKE_COMMAND", "CMAKE_C_COMPILER", "CMAKE_CXX_COMPILER", "CMAKE_HOME_DIRECTORY", "CMAKE_PROJECT_INCLUDE",
    "CMAKE_CACHE_MAJOR_VERSION", "CMAKE_CACHE_MINOR_VERSION", "CMAKE_CACHE_PATCH_VERSION", "CMAKE_MAKE_PROGRAM",
    "CMAKE_VS_PLATFORM_TOOLSET_VERSION", "CMAKE_C_COMPILER_LAUNCHER", "CMAKE_CXX_COMPILER_LAUNCHER",
]
# Ninja on Windows stores output times as 100 ns ticks since FILETIME + 12622770400 s (its TimestampFromFileTime);
# elsewhere as nanoseconds since 1970.
NINJA_EPOCH_WINDOWS = 12622770400 - 11644473600
LINK_KINDS = {"SHARED_LIBRARY": "DynamicLibrary", "MODULE": "DynamicLibrary", "STATIC_LIBRARY": "StaticLibrary",
              "EXECUTABLE": "Application"}


def read_text(path: Path) -> str:
    data = path.read_bytes()
    if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return data.decode("utf-16")
    return data.decode("utf-8", errors="replace")


def cache_values(tree: Path) -> dict:
    result = {}
    cache = tree / "CMakeCache.txt"
    if not cache.exists():
        return result
    for line in read_text(cache).splitlines():
        match = re.match(r"^([A-Za-z0-9_\-]+):[A-Z]+=(.*)$", line)
        if match and match.group(1) in CACHE_KEYS:
            result[match.group(1)] = match.group(2)
    return result


def file_times(paths):
    times = [p.stat().st_mtime for p in paths]
    return (min(times), max(times)) if times else (None, None)


# ---------------------------------------------------------------- Visual Studio trees

def release_group(text: str, element: str) -> dict:
    block = re.search(
        r"<ItemDefinitionGroup Condition=\"'\$\(Configuration\)\|\$\(Platform\)'=='Release\|x64'\">(.*?)</ItemDefinitionGroup>",
        text, re.S)
    if not block:
        return {}
    inner = re.search(rf"<{element}>(.*?)</{element}>", block.group(1), re.S)
    if not inner:
        return {}
    values = {}
    for name, value in re.findall(r"<(\w+)>(.*?)</\1>", inner.group(1), re.S):
        values[name] = value.strip()
    for name in re.findall(r"<(\w+)\s*/>", inner.group(1)):
        values.setdefault(name, "")
    return values


def release_property(text: str, name: str):
    for block in re.findall(r"<PropertyGroup Condition=\"'\$\(Configuration\)\|\$\(Platform\)'=='Release\|x64'\"[^>]*>(.*?)</PropertyGroup>", text, re.S):
        match = re.search(rf"<{name}>(.*?)</{name}>", block, re.S)
        if match:
            return match.group(1).strip()
    match = re.search(rf"<{name} Condition=\"'\$\(Configuration\)\|\$\(Platform\)'=='Release\|x64'\">(.*?)</{name}>", text, re.S)
    return match.group(1).strip() if match else None


def tlog_commands(tlog_dir: Path, prefix: str) -> list:
    commands = []
    if not tlog_dir.is_dir():
        return commands
    for path in sorted(tlog_dir.glob(prefix + ".command.*.tlog")):
        current = None
        for line in read_text(path).splitlines():
            if line.startswith("^"):
                current = line[1:]
            elif line.strip():
                commands.append({"sources": current, "command": line.strip()})
    return commands


def birth(path: Path):
    try:
        return path.stat().st_birthtime
    except AttributeError:
        return path.stat().st_ctime


def vcxproj_info(vcxproj: Path) -> dict:
    text = read_text(vcxproj)
    name = vcxproj.stem
    sources = re.findall(r"<ClCompile Include=\"([^\"]+)\"", text)
    masm = re.findall(r"<MASM Include=\"([^\"]+)\"", text)
    info = {
        "name": name,
        "generator": "Visual Studio",
        "vcxproj": str(vcxproj),
        "configurationType": release_property(text, "ConfigurationType"),
        "wholeProgramOptimization": release_property(text, "WholeProgramOptimization"),
        "useDebugLibraries": release_property(text, "UseDebugLibraries"),
        "platformToolset": release_property(text, "PlatformToolset"),
        "sources": len(sources),
        "sourceExtensions": sorted({Path(s).suffix.lower() for s in sources}),
        "masm": len(masm),
        "clCompile": release_group(text, "ClCompile"),
        "link": release_group(text, "Link"),
        "lib": release_group(text, "Lib"),
        "projectReferences": [Path(p).stem for p in re.findall(r"<ProjectReference Include=\"([^\"]+)\"", text)],
    }
    int_dir = vcxproj.parent / (name + ".dir") / "Release"
    objects = list(int_dir.glob("*.obj")) if int_dir.is_dir() else []
    first, last = file_times(objects)
    info["intDir"] = str(int_dir)
    info["objects"] = len(objects)
    info["objectBytes"] = sum(o.stat().st_size for o in objects)
    info["firstObjectWrite"] = first
    info["lastObjectWrite"] = last
    info["intDirCreated"] = birth(int_dir) if int_dir.is_dir() else None
    tlogs = sorted(int_dir.glob("*.tlog")) if int_dir.is_dir() else []
    tlog = tlogs[0] if tlogs else int_dir / (name + ".tlog")
    info["clCommands"] = tlog_commands(tlog, "CL")
    info["linkCommands"] = tlog_commands(tlog, "link")
    info["libCommands"] = tlog_commands(tlog, "Lib-link")
    states = list(tlog.glob("*.lastbuildstate")) if tlog.is_dir() else []
    info["lastBuildState"] = states[0].stat().st_mtime if states else None
    reads = sorted(tlog.glob("CL.read.*.tlog")) if tlog.is_dir() else []
    info["tlogCreated"] = birth(tlog) if tlog.is_dir() else None
    info["clReadCreated"] = birth(reads[0]) if reads else None
    info["clReadWritten"] = reads[0].stat().st_mtime if reads else None
    return info


def vs_projects(tree: Path) -> list:
    projects = []
    for vcxproj in sorted(tree.rglob("*.vcxproj")):
        rel = vcxproj.relative_to(tree).as_posix()
        if rel.startswith("CMakeFiles/") or "/CMakeFiles/" in rel or vcxproj.stem in SKIP_PROJECTS:
            continue
        if "_deps/" in rel and vcxproj.stem.endswith(("-populate", "-update")):
            continue
        projects.append(vcxproj_info(vcxproj))
    return projects


# ---------------------------------------------------------------- Ninja trees

def norm(path: str) -> str:
    return path.replace("/", "\\").lower()


def ninja_log(tree: Path) -> dict:
    """Latest .ninja_log entry per output, with absolute start and end seconds."""
    path = tree / ".ninja_log"
    entries = {}
    if not path.exists():
        return entries
    for line in read_text(path).splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 5:
            continue
        start, end, mtime = int(parts[0]), int(parts[1]), int(parts[2])
        stamp = (mtime / 1e7 + NINJA_EPOCH_WINDOWS if os.name == "nt" else mtime / 1e9) if mtime else None
        entries[norm(parts[3])] = {"startMs": start, "endMs": end, "mtime": stamp}
    # An edge's end is its output's time, so the ninja run started at the median of (output time - end offset).
    offsets = sorted(e["mtime"] - e["endMs"] / 1000 for e in entries.values() if e["mtime"])
    base = offsets[len(offsets) // 2] if offsets else None
    for e in entries.values():
        e["start"] = base + e["startMs"] / 1000 if base is not None else None
        e["end"] = base + e["endMs"] / 1000 if base is not None else None
    return entries


def log_entry(log: dict, tree: Path, output: str):
    key = norm(output)
    if key in log:
        return log[key]
    if Path(output).is_absolute():
        try:
            return log.get(norm(os.path.relpath(output, tree)))
        except ValueError:
            return None
    return log.get(norm(str(tree / output)))


def expand(template: str, variables: dict, out: str, source: str) -> str:
    """A Ninja rule's command with an edge's variables, $out and $in substituted."""
    values = dict(variables, out=out, **{"in": source})
    text = re.sub(r"\$\{(\w+)\}|\$(\w+)", lambda m: values.get(m.group(1) or m.group(2), ""), template)
    return " ".join(text.split())


def ninja_projects(tree: Path) -> list:
    text = read_text(tree / "build.ninja")
    rules = {}
    rules_file = tree / "CMakeFiles" / "rules.ninja"
    if rules_file.exists():
        current = None
        for line in read_text(rules_file).splitlines():
            if line.startswith("rule "):
                current = line[5:].strip()
            elif current and line.startswith("  command = "):
                rules[current] = line[len("  command = "):]
    commands = {}
    compile_db = tree / "compile_commands.json"
    if compile_db.exists():
        for entry in json.loads(read_text(compile_db)):
            output = entry.get("output") or ""
            full = output if Path(output).is_absolute() else str(Path(entry["directory"]) / output)
            commands[norm(full)] = {"sources": entry["file"], "command": entry["command"]}
    log = ninja_log(tree)
    targets = {}

    def target(name):
        return targets.setdefault(name, {"objects": [], "link": None})

    for block in re.split(r"\n(?=build )", text):
        head = block.split("\n", 1)[0]
        match = re.match(r"^build (.+?(?<!\$)): (\S+)(.*)$", head)
        if not match:
            continue
        outputs, rule, rest = match.group(1), match.group(2), match.group(3)
        variables = dict(re.findall(r"^  (\w+) = (.*)$", block, re.M))
        compile_rule = re.match(r"^(C|CXX|RC|ASM_MASM|ASM)_COMPILER__(.+?)_(?:unscanned_)?Release$", rule)
        link_rule = re.match(r"^(C|CXX)_(SHARED_LIBRARY|STATIC_LIBRARY|EXECUTABLE|MODULE)_LINKER__(.+?)_Release$", rule)
        if compile_rule:
            source = rest.split("||")[0].split("|")[0].strip().split(" ")[0].replace("$:", ":")
            target(compile_rule.group(2))["objects"].append(
                {"object": outputs.replace("$:", ":").strip(), "source": source, "lang": compile_rule.group(1), "vars": variables, "rule": rule})
        elif link_rule:
            output = outputs.replace("$:", ":").split(" ")[0]
            target(link_rule.group(3))["link"] = {"kind": link_rule.group(2), "rule": rule, "output": output, "vars": variables}
    projects = []
    for name, t in sorted(targets.items()):
        objects, cl, size, edges = [], [], 0, []
        for o in t["objects"]:
            path = Path(o["object"]) if Path(o["object"]).is_absolute() else tree / o["object"]
            if path.exists():
                objects.append(path)
                size += path.stat().st_size
                entry = log_entry(log, tree, o["object"])
                if entry and entry["start"] is not None:
                    edges.append(entry)
            if o["lang"] not in ("C", "CXX"):
                continue
            command = commands.get(norm(str(path)))
            if command is None:
                # compile_commands.json covers only targets that export it; expand the edge's rule instead.
                command = {"sources": o["source"], "command": expand(rules.get(o["rule"], "$DEFINES $FLAGS"), o["vars"], o["object"], o["source"])}
            cl.append(command)
        first, last = file_times(objects)
        link = t["link"]
        link_commands, lib_commands, link_entry = [], [], None
        if link:
            v = link["vars"]
            tool = "lib.exe" if link["kind"] == "STATIC_LIBRARY" else "link.exe"
            command = " ".join(f"{tool} /nologo {v.get('LINK_FLAGS', '')} {v.get('LINK_LIBRARIES', '')} /out:{link['output']}".split())
            (lib_commands if tool == "lib.exe" else link_commands).append(
                {"sources": link["output"], "command": command, "rule": rules.get(link["rule"], "")})
            link_entry = log_entry(log, tree, link["output"])
        first_vars = t["objects"][0]["vars"] if t["objects"] else {}
        projects.append({
            "name": name,
            "generator": "Ninja",
            "configurationType": LINK_KINDS.get(link["kind"]) if link else ("ObjectLibrary" if t["objects"] else None),
            "sources": len(t["objects"]),
            "sourceExtensions": sorted({Path(o["source"]).suffix.lower() for o in t["objects"]}),
            "masm": sum(1 for o in t["objects"] if o["lang"].startswith("ASM")),
            "clCompile": {"FLAGS": first_vars.get("FLAGS"), "DEFINES": first_vars.get("DEFINES"),
                          "LAUNCHER": (first_vars.get("LAUNCHER") or "").strip() or None},
            "link": {"LINK_FLAGS": link["vars"].get("LINK_FLAGS") if link else None},
            "lib": {},
            "objects": len(objects),
            "objectBytes": size,
            "firstObjectWrite": first,
            "lastObjectWrite": last,
            "clCommands": cl,
            "linkCommands": link_commands,
            "libCommands": lib_commands,
            "edges": len(edges),
            "edgeSeconds": round(sum(e["endMs"] - e["startMs"] for e in edges) / 1000, 2),
            "windowStart": min((e["start"] for e in edges), default=None),
            "windowEnd": max((e["end"] for e in edges), default=None),
            "linkStart": link_entry["start"] if link_entry else None,
            "linkEnd": link_entry["end"] if link_entry else None,
            "wholeProgramOptimization": None, "useDebugLibraries": None, "platformToolset": None, "projectReferences": [],
        })
    return projects


# ---------------------------------------------------------------- trees

def try_compiles(tree: Path):
    log = tree / "CMakeFiles" / "CMakeConfigureLog.yaml"
    if not log.exists():
        return None
    return len(re.findall(r'kind:\s*"try_(?:compile|run)-v1"', read_text(log)))


def tree_info(tree: Path) -> dict:
    ninja = (tree / "build.ninja").exists()
    info = {"tree": str(tree), "cache": cache_values(tree), "generator": "Ninja" if ninja else "Visual Studio",
            "projects": ninja_projects(tree) if ninja else vs_projects(tree), "tryCompiles": try_compiles(tree)}
    configure_log = tree / "CMakeFiles" / "CMakeConfigureLog.yaml"
    info["configureLogBytes"] = configure_log.stat().st_size if configure_log.exists() else None
    cache = tree / "CMakeCache.txt"
    if cache.exists():
        info["cacheWritten"] = cache.stat().st_mtime
        info["cacheCreated"] = birth(cache)
    deps = tree / "_deps"
    info["fetchContent"] = sorted(p.name for p in deps.iterdir()) if deps.is_dir() else []
    return info


def bootstrap(root: Path) -> list:
    """The haxeon bootstrap's Ninja trees: what the last build of each output cost."""
    result = []
    for name in ["cmake/windows-msvc", "libffi/msvc-x64-static-release", "libffi/msvc-x64-static-debug"]:
        path = root / "haxeon" / "out" / name / ".ninja_log"
        if not path.exists():
            continue
        last = {}
        for line in read_text(path).splitlines():
            parts = line.split("\t")
            if line and not line.startswith("#") and len(parts) >= 4:
                last[parts[3]] = (int(parts[0]), int(parts[1]))
        if not last:
            continue
        starts = [s for s, e in last.values()]
        ends = [e for s, e in last.values()]
        top = sorted(last.items(), key=lambda kv: -(kv[1][1] - kv[1][0]))[:6]
        result.append({"tree": f"haxeon/out/{name}", "outputs": len(last),
                       "edgeSeconds": round(sum(e - s for s, e in last.values()) / 1000, 1),
                       "spanSeconds": round((max(ends) - min(starts)) / 1000, 1),
                       "objects": sum(1 for o in last if o.endswith(".obj")),
                       "slowest": [[o.split("/")[-1], round((e - s) / 1000, 2)] for o, (s, e) in top],
                       "mtime": path.stat().st_mtime})
    return result


def main() -> int:
    root = Path(sys.argv[1])
    trees = []
    for app in ("agent", "suit", "graphical"):
        native = root / app / "build" / "host" / "native"
        if not native.is_dir():
            continue
        for package in sorted(native.iterdir()):
            if not package.is_dir():
                continue
            outputs = [{"name": p.name, "bytes": p.stat().st_size, "mtime": p.stat().st_mtime}
                       for p in sorted(package.iterdir()) if p.is_file()]
            for tree in sorted(p for p in package.iterdir() if p.is_dir() and p.name.startswith("cmake")):
                record = tree_info(tree)
                record.update({"app": app, "package": package.name, "outputs": outputs})
                trees.append(record)
    haxe = []
    for app in ("agent", "suit", "graphical"):
        host = root / app / "build" / "host"
        for name in ("main.hl", "main.hl.functions", "main.hl.live.json"):
            path = host / name
            if path.exists():
                haxe.append({"app": app, "name": name, "bytes": path.stat().st_size, "mtime": path.stat().st_mtime})
    result = {"root": str(root), "trees": trees, "haxeOutputs": haxe, "bootstrap": bootstrap(root)}
    Path(sys.argv[2]).write_text(json.dumps(result, indent=1))
    print(f"{len(trees)} trees, {sum(len(t['projects']) for t in trees)} projects")
    return 0


if __name__ == "__main__":
    sys.exit(main())
