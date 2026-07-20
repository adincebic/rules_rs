load("@bazel_skylib//lib:paths.bzl", "paths")
load("//rs/platforms:triples.bzl", "SUPPORTED_EXEC_TRIPLES")
load("//rs/private:cargo_toml_utils.bzl", "cargo_toml_is_proc_macro")
load("//rs/private:cfg_parser.bzl", "cfg_matches_expr_for_cfg_attrs", "triple_to_cfg_attrs")
load("//rs/private:resolver.bzl", "apply_dependency_edge", "dependency_resolution_triples", "resolve")
load("//rs/private:select_utils.bzl", "compute_select")
load("//rs/private:semver.bzl", "select_matching_version")

def platform_label(triple, use_legacy_rules_rust_platforms):
    if use_legacy_rules_rust_platforms:
        return "@rules_rust//rust/platform:" + triple.replace("-musl", "-gnu").replace("-gnullvm", "-msvc")
    return "@rules_rs//rs/platforms/config:" + triple

def fq_crate(name, version):
    return name + "-" + version

def normalize_path(path):
    return str(path).replace("\\", "/")

def manifest_package_dir(manifest_path, repo_root):
    package_dir = normalize_path(manifest_path).removeprefix(repo_root + "/")
    if package_dir == "Cargo.toml":
        return ""

    return package_dir.removesuffix("/Cargo.toml")

def add_to_dict(d, k, v):
    existing = d.get(k, [])
    if not existing:
        d[k] = existing
    existing.append(v)

def exclude_deps_from_features(features):
    return [f for f in features if not f.startswith("dep:")]

def shared_and_per_platform(platform_items, use_legacy_rules_rust_platforms):
    if not platform_items:
        return [], {}

    by_platform = {}
    for triple, items in platform_items.items():
        platform = platform_label(triple, use_legacy_rules_rust_platforms)
        existing = by_platform.get(platform)
        if existing == None:
            by_platform[platform] = set(items)
        else:
            existing.update(items)

    items, per_platform = compute_select([], by_platform)
    return sorted(items), per_platform

def select_items(items):
    return {k: sorted(v) for k, v in items.items()}

def render_string_list(items):
    return ",\n            ".join(['"%s"' % item for item in sorted(items)])

def cfg_match_info_for_target(target, platform_cfg_attrs, cfg_match_cache):
    match_info = cfg_match_cache.get(target)
    if match_info:
        return match_info

    match_info = cfg_matches_expr_for_cfg_attrs(target, platform_cfg_attrs)
    cfg_match_cache[target] = match_info
    return match_info

def exec_compatible_triples(platform_triples):
    return set([
        triple
        for triple in platform_triples
        if triple in SUPPORTED_EXEC_TRIPLES
    ])

def new_feature_resolutions(package_index, possible_deps, possible_features, platform_triples, is_proc_macro = False):
    return struct(
        features_enabled = {triple: set() for triple in platform_triples},
        build_deps = {triple: set() for triple in platform_triples},
        deps = {triple: set() for triple in platform_triples},
        aliases = {},
        is_proc_macro = is_proc_macro,
        package_index = package_index,
        possible_deps = possible_deps,
        possible_features = possible_features,
    )

_INTERNAL_RUSTC_PLACEHOLDER_CRATES = [
    "rustc-std-workspace-alloc",
    "rustc-std-workspace-core",
    "rustc-std-workspace-std",
]

def _is_internal_rustc_placeholder(crate_name):
    return crate_name in _INTERNAL_RUSTC_PLACEHOLDER_CRATES

def cargo_metadata_dep_to_dep_dict(dep):
    rename = dep.get("rename")
    converted = {
        "name": rename or dep["name"],
        "optional": dep.get("optional", False),
        "default_features": dep.get("uses_default_features", True),
        "features": list(dep.get("features", [])),
    }

    req = dep.get("req")
    if req:
        converted["req"] = req

    kind = dep.get("kind")
    if kind and kind != "normal":
        converted["kind"] = kind

    target = dep.get("target")
    if target:
        converted["target"] = target

    if rename:
        converted["package"] = dep["name"]

    return converted

def _cargo_toml_dep_to_dep_dict_inner(dep, spec, is_build = False, target = None):
    if type(spec) == "string":
        converted = {
            "name": dep,
            "req": spec,
        }
    else:
        converted = {
            "name": dep,
            "optional": spec.get("optional", False),
            "default_features": spec.get("default_features", spec.get("default-features", True)),
            "features": spec.get("features", []),
        }
        if "package" in spec:
            converted["package"] = spec["package"]
        if spec.get("version"):
            converted["req"] = spec["version"]

    if is_build:
        converted["kind"] = "build"

    if target:
        converted["target"] = target

    return converted

def cargo_toml_dep_to_dep_dict(dep, spec, package_name, workspace_cargo_toml_json = None, is_build = False, target = None):
    if type(spec) == "dict" and spec.get("workspace") == True:
        workspace = (workspace_cargo_toml_json or {}).get("workspace")
        if not workspace:
            fail("Package %s depends on %s with workspace inheritance, but no workspace section was found" % (package_name, dep))
        if dep not in workspace.get("dependencies", {}):
            fail("Package %s depends on %s with workspace inheritance, but it was not found in workspace.dependencies" % (package_name, dep))

        inherited = _cargo_toml_dep_to_dep_dict_inner(dep, workspace["dependencies"][dep], is_build = is_build, target = target)

        extra_features = spec.get("features")
        if extra_features:
            inherited["features"] = sorted(set(extra_features + inherited.get("features", [])))

        if spec.get("optional"):
            inherited["optional"] = True

        if spec.get("package"):
            inherited["package"] = spec["package"]

        return inherited

    return _cargo_toml_dep_to_dep_dict_inner(dep, spec, is_build = is_build, target = target)

def cargo_toml_dependencies(cargo_toml_json, workspace_cargo_toml_json = None):
    package_name = cargo_toml_json["package"]["name"]
    dependencies = [
        cargo_toml_dep_to_dep_dict(dep, spec, package_name, workspace_cargo_toml_json)
        for dep, spec in cargo_toml_json.get("dependencies", {}).items()
    ] + [
        cargo_toml_dep_to_dep_dict(dep, spec, package_name, workspace_cargo_toml_json, is_build = True)
        for dep, spec in cargo_toml_json.get("build-dependencies", {}).items()
    ]

    for target, value in cargo_toml_json.get("target", {}).items():
        for dep, spec in value.get("dependencies", {}).items():
            dependencies.append(cargo_toml_dep_to_dep_dict(
                dep,
                spec,
                package_name,
                workspace_cargo_toml_json,
                target = target,
            ))
        for dep, spec in value.get("build-dependencies", {}).items():
            dependencies.append(cargo_toml_dep_to_dep_dict(
                dep,
                spec,
                package_name,
                workspace_cargo_toml_json,
                is_build = True,
                target = target,
            ))

    return dependencies

def cargo_toml_fact(cargo_toml_json, workspace_cargo_toml_json = None, strip_prefix = ""):
    return dict(
        features = cargo_toml_json.get("features", {}),
        dependencies = cargo_toml_dependencies(cargo_toml_json, workspace_cargo_toml_json),
        is_proc_macro = cargo_toml_is_proc_macro(cargo_toml_json),
        strip_prefix = strip_prefix,
    )

def _cargo_metadata_package_is_proc_macro(package):
    for target in package.get("targets", []):
        if "proc-macro" in target.get("kind", []) or "proc-macro" in target.get("crate_types", []):
            return True
    return False

def prepare_possible_deps(dependencies, converter = None, skip_internal_rustc_placeholder_crates = True):
    possible_deps = []

    for dep in dependencies:
        if converter:
            dep = converter(dep)
        else:
            dep = dict(dep)

            # Dependency features originate in persisted facts. Copy the list
            # before adding the implicit default feature so resolution cannot
            # mutate the cached fact in place.
            if "features" in dep:
                dep["features"] = list(dep["features"])

        if dep.get("kind") == "dev":
            continue

        dep_package = dep.get("package") or dep["name"]
        if skip_internal_rustc_placeholder_crates and _is_internal_rustc_placeholder(dep_package):
            continue

        if dep.get("default_features", True):
            add_to_dict(dep, "features", "default")

        possible_deps.append(dep)

    return possible_deps

def _dep_package_name(dep):
    return dep.get("package") or dep["name"]

def compute_package_fq_deps(package, versions_by_name, strict = True):
    possible_dep_fq_crates_by_name = {}

    for maybe_fq_dep in package.get("dependencies", []):
        idx = maybe_fq_dep.find(" ")
        if idx == -1:
            versions = versions_by_name.get(maybe_fq_dep)
            if not versions:
                if strict:
                    fail("Malformed lockfile?")
                continue
            dep = maybe_fq_dep
            resolved_version = versions[0]
        else:
            dep = maybe_fq_dep[:idx]
            resolved_version = maybe_fq_dep[idx + 1:]

        add_to_dict(possible_dep_fq_crates_by_name, dep, fq_crate(dep, resolved_version))

    return possible_dep_fq_crates_by_name

def select_package_fq_dep(dep, fq_deps):
    dep_package = _dep_package_name(dep)
    candidates = fq_deps.get(dep_package)
    if not candidates:
        return None

    if len(candidates) == 1:
        return candidates[0]

    req = dep.get("req")
    if not req:
        return None

    versions = [
        candidate[len(dep_package) + 1:]
        for candidate in candidates
    ]
    version = select_matching_version(req, versions)
    if not version:
        return None

    return fq_crate(dep_package, version)

def compute_workspace_fq_deps(workspace_members, versions_by_name):
    workspace_fq_deps = {}

    for workspace_member in workspace_members:
        fq_deps = compute_package_fq_deps(workspace_member, versions_by_name, strict = False)
        workspace_fq_deps[workspace_member["name"]] = fq_deps

    return workspace_fq_deps

def _relative_to_workspace(path, workspace_root):
    normalized_root = normalize_path(workspace_root)
    normalized_path = normalize_path(path)

    if not paths.is_absolute(normalized_path):
        normalized_path = normalize_path(paths.normalize(paths.join(normalized_root, normalized_path)))

    root_parts = [p for p in normalized_root.split("/") if p]
    path_parts = [p for p in normalized_path.split("/") if p]

    common = 0
    max_common = min(len(root_parts), len(path_parts))
    for idx in range(max_common):
        if root_parts[idx] != path_parts[idx]:
            break
        common = idx + 1

    rel_parts = [".."] * (len(root_parts) - common) + path_parts[common:]
    return "/".join(rel_parts) if rel_parts else "."

def _cargo_metadata_dep_paths_by_name(packages, workspace_root):
    package_dirs = {}

    for package in packages:
        for dep in package.get("dependencies", []):
            dep_path = dep.get("path")
            if not dep_path:
                continue

            package_dirs[dep["name"]] = _relative_to_workspace(dep_path, workspace_root)

    return package_dirs

def _cargo_toml_patch_paths_by_name(workspace_cargo_toml, workspace_root, workspace_package_dir = ""):
    workspace_root = normalize_path(workspace_root)
    workspace_root_prefix = workspace_root + "/"
    package_dirs = {}

    for patches in workspace_cargo_toml.get("patch", {}).values():
        for name, spec in patches.items():
            if type(spec) != "dict":
                continue

            patch_path = spec.get("path")
            if not patch_path:
                continue

            package = spec.get("package") or name
            if paths.is_absolute(patch_path):
                normalized = normalize_path(patch_path)
                if not normalized.startswith(workspace_root_prefix):
                    fail("Patch path for %s points outside the workspace: %s" % (name, patch_path))
                package_dirs[package] = normalized.removeprefix(workspace_root_prefix)
            else:
                package_dirs[package] = normalize_path(paths.normalize(paths.join(workspace_package_dir, patch_path)))

    return package_dirs

def split_lockfile_packages(hub_name, cargo_metadata, workspace_cargo_toml, all_packages, repo_root = None, workspace_package_dir = ""):
    if repo_root == None:
        repo_root = cargo_metadata["workspace_root"]
    repo_root = normalize_path(repo_root)

    workspace_member_keys = {}
    for package in cargo_metadata["packages"]:
        workspace_member_keys[(package["name"], package["version"])] = True

    dep_paths_by_name = _cargo_metadata_dep_paths_by_name(cargo_metadata["packages"], repo_root)
    patch_paths_by_name = _cargo_toml_patch_paths_by_name(workspace_cargo_toml, repo_root, workspace_package_dir)
    workspace_members = []
    packages = []

    for package in all_packages:
        pkg = dict(package)

        if pkg.get("source"):
            packages.append(pkg)
            continue

        key = (pkg["name"], pkg["version"])
        if key in workspace_member_keys:
            workspace_members.append(pkg)
            continue

        rel_path = patch_paths_by_name.get(pkg["name"]) or dep_paths_by_name.get(pkg["name"])
        local_path = rel_path
        if rel_path and not rel_path.startswith("/"):
            local_path = paths.join(repo_root, rel_path)

        if not local_path:
            fail("Found a path dependency on %s %s but could not determine its path from Cargo.toml. Please declare it in [patch] or as a path dependency." % (pkg["name"], pkg["version"]))

        pkg["source"] = "path+" + hub_name + "/" + rel_path
        pkg["local_path"] = local_path
        packages.append(pkg)

    return struct(
        packages = packages,
        workspace_members = workspace_members,
    )

def _resolve_packages(packages, package_info_by_fq_crate, platform_triples, dep_converter = None, skip_internal_rustc_placeholder_crates = True):
    feature_resolutions_by_fq_crate = {}
    versions_by_name = {}

    for package_index in range(len(packages)):
        package = packages[package_index]
        name = package["name"]
        version = package["version"]
        fq = fq_crate(name, version)

        add_to_dict(versions_by_name, name, version)

        package_info = package_info_by_fq_crate[fq]
        possible_deps = prepare_possible_deps(
            package_info.get("dependencies", []),
            converter = dep_converter,
            skip_internal_rustc_placeholder_crates = skip_internal_rustc_placeholder_crates,
        )
        feature_resolutions = new_feature_resolutions(
            package_index,
            possible_deps,
            package_info.get("features", {}),
            platform_triples,
            is_proc_macro = package.get("is_proc_macro", False) or package_info.get("is_proc_macro", False) or _cargo_metadata_package_is_proc_macro(package_info),
        )
        package["feature_resolutions"] = feature_resolutions
        feature_resolutions_by_fq_crate[fq] = feature_resolutions

    return struct(
        feature_resolutions_by_fq_crate = feature_resolutions_by_fq_crate,
        versions_by_name = versions_by_name,
    )

def resolve_package_facts(packages, facts_by_fq_crate, platform_triples, skip_internal_rustc_placeholder_crates = True):
    return _resolve_packages(
        packages,
        facts_by_fq_crate,
        platform_triples,
        skip_internal_rustc_placeholder_crates = skip_internal_rustc_placeholder_crates,
    )

def registry_crate_kind_candidates(packages, facts_by_fq_crate, platform_triples):
    """Returns registry crates whose unknown kind can affect resolution.

    Args:
        packages: Resolved lockfile packages.
        facts_by_fq_crate: Manifest-derived facts keyed by fully qualified crate.
        platform_triples: Target and execution triples participating in resolution.

    Returns:
        Registry packages whose proc-macro status has not yet been established
        and could change feature or dependency resolution.
    """
    if len(platform_triples) < 2:
        return []

    candidates = []
    for package in packages:
        if not package.get("source", "").startswith("sparse+"):
            continue

        fq = fq_crate(package["name"], package["version"])
        fact = facts_by_fq_crate[fq]
        feature_resolutions = package["feature_resolutions"]
        if "is_proc_macro" in fact or feature_resolutions.is_proc_macro:
            continue

        features_enabled = feature_resolutions.features_enabled
        baseline = features_enabled[platform_triples[0]]
        if any([features_enabled[triple] != baseline for triple in platform_triples[1:]]):
            candidates.append(package)

    return candidates

def resolve_cargo_metadata_packages(packages, cargo_metadata, platform_triples, skip_internal_rustc_placeholder_crates = True):
    metadata_by_fq_crate = {
        fq_crate(package["name"], package["version"]): package
        for package in cargo_metadata["packages"]
    }

    return _resolve_packages(
        packages,
        metadata_by_fq_crate,
        platform_triples,
        dep_converter = cargo_metadata_dep_to_dep_dict,
        skip_internal_rustc_placeholder_crates = skip_internal_rustc_placeholder_crates,
    )

def _resolve_possible_deps(
        packages,
        resolver_versions_by_name,
        feature_resolutions_by_fq_crate,
        platform_triples,
        platform_cfg_attrs,
        cfg_match_cache,
        dep_label_prefix):
    for package in packages:
        name = package["name"]
        deps_by_name = {}
        for maybe_fq_dep in package.get("dependencies", []):
            idx = maybe_fq_dep.find(" ")
            if idx != -1:
                dep = maybe_fq_dep[:idx]
                resolved_version = maybe_fq_dep[idx + 1:]
                add_to_dict(deps_by_name, dep, resolved_version)

        for dep in package["feature_resolutions"].possible_deps:
            dep_package = _dep_package_name(dep)

            versions = resolver_versions_by_name.get(dep_package)
            if not versions:
                continue
            constrained_versions = deps_by_name.get(dep_package)
            if constrained_versions:
                versions = constrained_versions

            if len(versions) == 1:
                resolved_version = versions[0]
            else:
                req = dep.get("req")
                if not req:
                    continue

                resolved_version = select_matching_version(req, versions)
                if not resolved_version:
                    if not dep.get("optional"):
                        print("WARNING: %s: could not resolve %s %s among %s" % (name, dep_package, req, versions))
                    continue

            dep_fq = fq_crate(dep_package, resolved_version)
            if dep_fq not in feature_resolutions_by_fq_crate:
                fail("Resolved %s dependency %s but no crate metadata was available" % (name, dep_fq))
            dep["bazel_target"] = "%s%s" % (dep_label_prefix, dep_fq)
            dep["feature_resolutions"] = feature_resolutions_by_fq_crate[dep_fq]

            target = dep.get("target")
            match_info = cfg_match_info_for_target(target, platform_cfg_attrs, cfg_match_cache)
            if match_info.uses_feature_cfg:
                dep["target_expr"] = target
                dep["feature_sensitive"] = True
                dep["target"] = set(platform_triples)
            else:
                dep["target"] = set(match_info.matches)

def resolve_cargo_workspace_members(
        ctx,
        *,
        cargo_metadata,
        packages,
        workspace_members,
        versions_by_name,
        feature_resolutions_by_fq_crate,
        annotations,
        platform_triples,
        materialize_workspace_members,
        validate_lockfile = True,
        debug = False,
        dep_label_prefix = "//:",
        skip_internal_rustc_placeholder_crates = True,
        watch_manifests = False,
        use_legacy_rules_rust_platforms = False):
    platform_cfg_attrs = [triple_to_cfg_attrs(triple) for triple in platform_triples]
    platform_cfg_attrs_by_triple = {}
    for cfg_attr in platform_cfg_attrs:
        platform_cfg_attrs_by_triple[cfg_attr["_triple"]] = cfg_attr

    cfg_match_cache = {None: struct(matches = platform_triples, uses_feature_cfg = False)}
    exec_triples = exec_compatible_triples(platform_triples)
    if not exec_triples:
        fail(
            "platform_triples must include at least one supported execution triple for build dependencies and procedural macros. " +
            "Add one of %s; got %s" % (SUPPORTED_EXEC_TRIPLES, platform_triples),
        )

    workspace_member_keys = {}
    for package in cargo_metadata["packages"]:
        workspace_member_keys[(package["name"], package["version"])] = True

    resolver_versions_by_name = {name: versions[:] for name, versions in versions_by_name.items()}
    workspace_members_by_key = {(package["name"], package["version"]): package for package in workspace_members}
    resolver_packages = packages[:]
    for package in cargo_metadata["packages"]:
        name = package["name"]
        version = package["version"]

        versions = resolver_versions_by_name.get(name, [])
        if version not in versions:
            if versions:
                versions.append(version)
            else:
                resolver_versions_by_name[name] = [version]

        possible_features = package.get("features", {})
        possible_deps = prepare_possible_deps(
            package.get("dependencies", []),
            converter = cargo_metadata_dep_to_dep_dict,
            skip_internal_rustc_placeholder_crates = skip_internal_rustc_placeholder_crates,
        )

        package_index = len(resolver_packages)
        lockfile_pkg = workspace_members_by_key.get((name, version), {})
        resolver_package = {
            "name": name,
            "version": version,
            "dependencies": lockfile_pkg.get("dependencies", []),
        }

        feature_resolutions = new_feature_resolutions(
            package_index,
            possible_deps,
            possible_features,
            platform_triples,
            is_proc_macro = _cargo_metadata_package_is_proc_macro(package),
        )
        resolver_package["feature_resolutions"] = feature_resolutions
        feature_resolutions_by_fq_crate[fq_crate(name, version)] = feature_resolutions

        resolver_packages.append(resolver_package)

    _resolve_possible_deps(
        resolver_packages,
        resolver_versions_by_name,
        feature_resolutions_by_fq_crate,
        platform_triples,
        platform_cfg_attrs,
        cfg_match_cache,
        dep_label_prefix,
    )

    workspace_fq_deps = compute_workspace_fq_deps(workspace_members, resolver_versions_by_name)
    workspace_dep_versions_by_name = {}
    workspace_dep_labels_by_triple = {triple: set() for triple in platform_triples}

    for package in cargo_metadata["packages"]:
        if watch_manifests:
            ctx.watch(package["manifest_path"])

        package_feature_resolutions = feature_resolutions_by_fq_crate[fq_crate(package["name"], package["version"])]
        if "default" in package.get("features", {}):
            resolution_triples = exec_triples if package_feature_resolutions.is_proc_macro else platform_triples
            for triple in resolution_triples:
                package_feature_resolutions.features_enabled[triple].add("default")

        fq_deps = workspace_fq_deps.get(package["name"], {})

        for dep in package["dependencies"]:
            source = dep.get("source")
            dep_name = dep["name"]
            dep_package = _dep_package_name(dep)
            dep_fq = select_package_fq_dep(dep, fq_deps)
            dep_version = None
            if dep_fq:
                dep_version = dep_fq[len(dep_package) + 1:]
            is_first_party_dep = not source and dep_version and (dep_package, dep_version) in workspace_member_keys

            if validate_lockfile and source and source.startswith("registry+"):
                req = dep["req"]
                fq = dep_fq
                if req and fq:
                    locked_version = fq[len(dep_package) + 1:]
                    if not select_matching_version(req, [locked_version]):
                        fail(("ERROR: Cargo.lock out of sync: %s requires %s %s but Cargo.lock has %s.\n\n" +
                              "If this is incorrect, please set `validate_lockfile = False` in `crate.from_cargo`\n" +
                              "and file a bug at https://github.com/hermeticbuild/rules_rs/issues/new") % (
                            package["name"],
                            dep_package,
                            req,
                            locked_version,
                        ))

            if not dep_fq:
                continue

            if dep_fq not in feature_resolutions_by_fq_crate:
                fail("Resolved %s dependency %s but no crate metadata was available" % (package["name"], dep_fq))

            if not is_first_party_dep or materialize_workspace_members:
                dep["bazel_target"] = "%s%s" % (dep_label_prefix, dep_fq)

            feature_resolutions = feature_resolutions_by_fq_crate[dep_fq]

            if not is_first_party_dep or materialize_workspace_members:
                versions = workspace_dep_versions_by_name.get(dep_name)
                if not versions:
                    versions = set()
                    workspace_dep_versions_by_name[dep_name] = versions
                versions.add(dep_fq)

            target = dep.get("target")
            match_info = cfg_match_info_for_target(target, platform_cfg_attrs, cfg_match_cache)

            for triple in match_info.matches:
                # Dev dependencies are intentionally excluded from possible_deps so
                # they do not become normal Bazel dependencies. They are still
                # Cargo roots when building workspace tests, so their requested
                # features and transitive dependencies must be resolved.
                if dep.get("kind") == "dev":
                    apply_dependency_edge(
                        dep,
                        feature_resolutions,
                        triple,
                        exec_triples,
                        package_feature_resolutions.features_enabled[triple],
                        platform_cfg_attrs_by_triple,
                        features = dep.get("features", []),
                        uses_default_features = dep.get("uses_default_features", True),
                    )

                if not is_first_party_dep or materialize_workspace_members:
                    workspace_dep_labels_by_triple[triple].add(":" + dep_name)

    for crate, annotation_versions in annotations.items():
        for version_key, annotation in annotation_versions.items():
            target_versions = resolver_versions_by_name.get(crate, [])
            if version_key != "*":
                if version_key not in target_versions:
                    continue
                target_versions = [version_key]
            if not annotation.crate_features and not annotation.crate_features_select:
                continue
            for version in target_versions:
                feature_resolutions = feature_resolutions_by_fq_crate[fq_crate(crate, version)]
                features_enabled = feature_resolutions.features_enabled
                if annotation.crate_features:
                    resolution_triples = exec_triples if feature_resolutions.is_proc_macro else platform_triples
                    for triple in resolution_triples:
                        features_enabled[triple].update(annotation.crate_features)
                for triple, features in annotation.crate_features_select.items():
                    if triple not in features_enabled:
                        continue
                    if feature_resolutions.is_proc_macro:
                        for exec_triple in exec_triples:
                            features_enabled[exec_triple].update(features)
                    else:
                        features_enabled[triple].update(features)

    resolve(ctx, resolver_packages, feature_resolutions_by_fq_crate, platform_cfg_attrs_by_triple, debug, exec_triples)

    for package in packages:
        feature_resolutions = package["feature_resolutions"]
        features_enabled = feature_resolutions.features_enabled

        for dep in feature_resolutions.possible_deps:
            if "bazel_target" in dep:
                continue

            prefixed_dep_alias = "dep:" + dep["name"]

            for triple in platform_triples:
                if prefixed_dep_alias in features_enabled[triple]:
                    fail("Crate %s has enabled %s but it was not in the lockfile..." % (package["name"], prefixed_dep_alias))

    return struct(
        cfg_match_cache = cfg_match_cache,
        feature_resolutions_by_fq_crate = feature_resolutions_by_fq_crate,
        platform_cfg_attrs = platform_cfg_attrs,
        platform_cfg_attrs_by_triple = platform_cfg_attrs_by_triple,
        resolver_versions_by_name = resolver_versions_by_name,
        workspace_dep_labels_by_triple = workspace_dep_labels_by_triple,
        workspace_dep_versions_by_name = workspace_dep_versions_by_name,
        workspace_fq_deps = workspace_fq_deps,
        workspace_member_keys = workspace_member_keys,
    )

def workspace_dep_data(
        *,
        cargo_metadata,
        feature_resolutions_by_fq_crate,
        platform_triples,
        platform_cfg_attrs,
        cfg_match_cache,
        repo_root,
        workspace_package,
        use_legacy_rules_rust_platforms):
    dep_data = {}
    exec_triples = exec_compatible_triples(platform_triples)
    platform_cfg_attrs_by_triple = {
        cfg_attr["_triple"]: cfg_attr
        for cfg_attr in platform_cfg_attrs
    }

    for package in cargo_metadata["packages"]:
        aliases = {}
        crate_features = {triple: set() for triple in platform_triples}
        deps = {triple: set() for triple in platform_triples}
        build_deps = {triple: set() for triple in platform_triples}
        dev_deps = {triple: set() for triple in platform_triples}
        package_dir = manifest_package_dir(package["manifest_path"], repo_root)
        package_manifest_dir = normalize_path(package["manifest_path"]).removesuffix("/Cargo.toml")
        binaries = {}
        shared_libraries = {}
        feature_resolutions = feature_resolutions_by_fq_crate.get(fq_crate(package["name"], package["version"]))

        for target in package.get("targets", []):
            kinds = target.get("kind", [])
            if "cdylib" not in kinds and "bin" not in kinds:
                continue

            src_path = target.get("src_path")
            if not src_path:
                continue

            entrypoint = normalize_path(src_path).removeprefix(repo_root + "/")
            if package_dir and entrypoint.startswith(package_dir + "/"):
                entrypoint = entrypoint.removeprefix(package_dir + "/")

            if "cdylib" in kinds:
                shared_libraries[target["name"]] = entrypoint
            elif "bin" in kinds:
                binaries[target["name"]] = entrypoint

        for dep in package["dependencies"]:
            bazel_target = dep.get("bazel_target")
            dep_path = dep.get("path")
            if not bazel_target:
                if not dep_path:
                    continue
                bazel_target = "//" + paths.join(workspace_package, normalize_path(dep_path).removeprefix(repo_root + "/"))

            is_self_dep = dep_path and normalize_path(dep_path) == package_manifest_dir

            if not is_self_dep:
                if dep.get("rename"):
                    aliases[bazel_target] = dep["rename"].replace("-", "_")
                elif dep_path:
                    aliases[bazel_target] = dep["name"].replace("-", "_")

            target = dep.get("target")
            match_info = cfg_match_info_for_target(target, platform_cfg_attrs, cfg_match_cache)

            kind = dep["kind"]
            if kind == "dev":
                target_deps = dev_deps
            elif kind == "build":
                target_deps = build_deps
            else:
                target_deps = deps

            if kind == "build":
                match = platform_triples
                resolution_dep = dict(dep)
                if match_info.uses_feature_cfg:
                    resolution_dep["feature_sensitive"] = True
                    resolution_dep["target_expr"] = target
                    resolution_dep["target"] = set(platform_triples)
                else:
                    resolution_dep["target"] = set(match_info.matches)
            elif match_info.uses_feature_cfg:
                match = [
                    triple
                    for triple in platform_triples
                    if cfg_matches_expr_for_cfg_attrs(
                        target,
                        [platform_cfg_attrs_by_triple[triple]],
                        features = feature_resolutions.features_enabled[triple] if feature_resolutions else [],
                    ).matches
                ]
            else:
                match = match_info.matches

            if _cargo_metadata_package_is_proc_macro(package):
                match = [triple for triple in match if triple in exec_triples]

            for triple in match:
                triple_features = feature_resolutions.features_enabled[triple] if feature_resolutions else set()
                if dep.get("optional") and feature_resolutions:
                    dep_name = dep.get("rename") or dep["name"]
                    if dep_name not in triple_features and ("dep:" + dep_name) not in triple_features:
                        continue

                if is_self_dep:
                    continue

                if kind == "build":
                    for exec_triple in dependency_resolution_triples(
                        resolution_dep,
                        False,
                        triple,
                        exec_triples,
                        triple_features,
                        platform_cfg_attrs_by_triple,
                    ):
                        target_deps[exec_triple].add(bazel_target)
                else:
                    target_deps[triple].add(bazel_target)

        if feature_resolutions:
            for triple in platform_triples:
                crate_features[triple].update(exclude_deps_from_features(feature_resolutions.features_enabled[triple]))

        bazel_package = paths.join(workspace_package, package_dir) if package_dir else workspace_package

        crate_features, crate_features_by_platform = shared_and_per_platform(crate_features, use_legacy_rules_rust_platforms)
        deps, deps_by_platform = shared_and_per_platform(deps, use_legacy_rules_rust_platforms)
        build_deps, build_deps_by_platform = shared_and_per_platform(build_deps, use_legacy_rules_rust_platforms)
        dev_deps, dev_deps_by_platform = shared_and_per_platform(dev_deps, use_legacy_rules_rust_platforms)

        dep_data[bazel_package] = {
            "aliases": aliases,
            "binaries": binaries,
            "build_deps": build_deps,
            "build_deps_by_platform": build_deps_by_platform,
            "crate_features": crate_features,
            "crate_features_by_platform": crate_features_by_platform,
            "deps": deps,
            "deps_by_platform": deps_by_platform,
            "dev_deps": dev_deps,
            "dev_deps_by_platform": dev_deps_by_platform,
            "shared_libraries": shared_libraries,
        }

    return dep_data

def render_dep_data(dep_data):
    return "DEP_DATA = {\n%s\n}\n\n" % "\n".join([
        "    %s: %s," % (repr(package), repr(dep_data[package]))
        for package in sorted(dep_data.keys())
    ])
