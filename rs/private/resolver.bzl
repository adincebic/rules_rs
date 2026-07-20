load("//rs/private:cfg_parser.bzl", "cfg_matches_expr_for_cfg_attrs")

def _count(feature_resolutions_by_fq_crate):
    n = 0
    for feature_resolutions in feature_resolutions_by_fq_crate.values():
        for features in feature_resolutions.features_enabled.values():
            n += len(features)

        for build_deps in feature_resolutions.build_deps.values():
            n += len(build_deps)

        for deps in feature_resolutions.deps.values():
            n += len(deps)

        # No need to count aliases, they only get set when deps are set.
    return n

def _dep_target_matches_triple(dep, triple, package_feature_set, cfg_attrs_by_triple):
    remaining = dep["target"]
    if triple not in remaining:
        return False

    if not dep.get("feature_sensitive", False):
        return True

    cfg_attr = cfg_attrs_by_triple[triple]
    return bool(cfg_matches_expr_for_cfg_attrs(
        dep["target_expr"],
        [cfg_attr],
        features = package_feature_set,
    ).matches)

def dependency_resolution_triples(
        dep,
        is_proc_macro,
        triple,
        exec_triples,
        package_feature_set,
        cfg_attrs_by_triple):
    """Returns the configurations in which a dependency is compiled.

    Normal libraries stay in the requesting target configuration. Build
    dependencies and proc macros execute during the build. Target-specific
    build dependencies are selected against the host, so retain their target
    predicate while remapping them to execution-capable triples.

    Args:
        dep: Prepared dependency edge.
        is_proc_macro: Whether the dependency target is a procedural macro.
        triple: Configuration requesting the dependency.
        exec_triples: Execution-capable triples in the resolution universe.
        package_feature_set: Enabled features on the package owning the edge.
        cfg_attrs_by_triple: Parsed cfg attributes keyed by triple.

    Returns:
        The triples in which the dependency must be resolved.
    """
    if dep.get("kind", "normal") == "build":
        return set([
            exec_triple
            for exec_triple in exec_triples
            if _dep_target_matches_triple(dep, exec_triple, package_feature_set, cfg_attrs_by_triple)
        ])
    if is_proc_macro:
        return exec_triples
    return set([triple])

def apply_dependency_edge(
        dep,
        dep_feature_resolutions,
        triple,
        exec_triples,
        package_feature_set,
        cfg_attrs_by_triple,
        features = (),
        uses_default_features = False):
    """Applies a dependency edge's requested features to its configurations.

    Args:
        dep: Prepared dependency edge.
        dep_feature_resolutions: Resolution state for the dependency target.
        triple: Configuration requesting the dependency.
        exec_triples: Execution-capable triples in the resolution universe.
        package_feature_set: Enabled features on the package owning the edge.
        cfg_attrs_by_triple: Parsed cfg attributes keyed by triple.
        features: Features requested by this edge.
        uses_default_features: Whether this edge also requests `default`.

    Returns:
        Whether any dependency feature set changed.
    """
    changed = False
    for dep_triple in dependency_resolution_triples(
        dep,
        dep_feature_resolutions.is_proc_macro,
        triple,
        exec_triples,
        package_feature_set,
        cfg_attrs_by_triple,
    ):
        triple_features = dep_feature_resolutions.features_enabled[dep_triple]
        previous_length = len(triple_features)
        triple_features.update(features)
        if uses_default_features:
            triple_features.add("default")
        if previous_length != len(triple_features):
            changed = True
    return changed

def _resolve_one_round(packages, dirty_package_indices, cfg_attrs_by_triple, debug, exec_triples):
    new_dirty_package_indices = set()

    for index in dirty_package_indices:
        package = packages[index]
        package_changed = False

        feature_resolutions = package["feature_resolutions"]
        features_enabled = feature_resolutions.features_enabled

        deps = feature_resolutions.deps

        if _propagate_feature_enablement(
            package_changed,
            new_dirty_package_indices,
            package,
            features_enabled,
            feature_resolutions,
            cfg_attrs_by_triple,
            debug,
            exec_triples,
        ):
            package_changed = True

        # Propagate features across currently enabled dependencies.
        for dep in feature_resolutions.possible_deps:
            bazel_target = dep.get("bazel_target")
            if not bazel_target:
                continue

            kind = dep.get("kind", "normal")

            dep_feature_resolutions = dep["feature_resolutions"]

            has_alias = "package" in dep
            dep_name = dep["name"]
            prefixed_dep_alias = "dep:" + dep_name
            optional = dep.get("optional", False)

            if kind == "build":
                # Build dependencies are selected using the requesting crate's
                # target features, but their target predicate is evaluated in
                # the execution configuration. Consider every requesting
                # target here and let dependency_resolution_triples filter the
                # execution triples below.
                match = set(features_enabled.keys())
            elif dep.get("feature_sensitive"):
                match = set([
                    triple
                    for triple in dep["target"]
                    if _dep_target_matches_triple(dep, triple, features_enabled[triple], cfg_attrs_by_triple)
                ])
            else:
                match = set(dep["target"])

            # A procedural macro and its dependency graph are compiled in the
            # execution configuration. This also prevents host-only feature
            # requests from leaking into non-executable target triples.
            if feature_resolutions.is_proc_macro:
                match.intersection_update(exec_triples)

            for triple in match:
                if optional:
                    features_for_triple = features_enabled[triple]
                    if dep_name not in features_for_triple and prefixed_dep_alias not in features_for_triple:
                        continue

                dep_triples = dependency_resolution_triples(
                    dep,
                    dep_feature_resolutions.is_proc_macro,
                    triple,
                    exec_triples,
                    features_enabled[triple],
                    cfg_attrs_by_triple,
                )
                if not dep_triples:
                    continue

                if kind == "build":
                    label_triples = dep_triples
                    triple_deps_by_triple = feature_resolutions.build_deps
                else:
                    label_triples = [triple]
                    triple_deps_by_triple = deps

                for label_triple in label_triples:
                    triple_deps = triple_deps_by_triple[label_triple]
                    if bazel_target not in triple_deps:
                        package_changed = True
                        triple_deps.add(bazel_target)

                if has_alias:
                    feature_resolutions.aliases[bazel_target] = dep_name.replace("-", "_")

                if apply_dependency_edge(
                    dep,
                    dep_feature_resolutions,
                    triple,
                    exec_triples,
                    features_enabled[triple],
                    cfg_attrs_by_triple,
                    features = dep.get("features", []),
                ):
                    new_dirty_package_indices.add(dep_feature_resolutions.package_index)
        if package_changed:
            new_dirty_package_indices.add(index)

    return new_dirty_package_indices

def _propagate_feature_enablement(
        package_changed,
        dirty_package_indices,
        package,
        features_enabled,
        feature_resolutions,
        cfg_attrs_by_triple,
        debug,
        exec_triples):
    possible_features = feature_resolutions.possible_features

    for triple, feature_set in features_enabled.items():
        if feature_resolutions.is_proc_macro and triple not in exec_triples:
            continue

        if not feature_set:
            continue

        # Enable any features that are implied by previously-enabled features.
        for enabled_feature in list(feature_set):
            enables = possible_features.get(enabled_feature)
            if not enables:
                continue

            for feature in enables:
                idx = feature.find("/")
                if idx == -1:
                    if feature not in feature_set:
                        package_changed = True
                        feature_set.add(feature)
                    continue

                dep_name = feature[:idx]
                dep_feature = feature[idx + 1:]

                dep_optional = False
                optional_marker = False
                if dep_name[-1] == "?":
                    optional_marker = True
                    dep_name = dep_name[:-1]

                found = False
                for dep in feature_resolutions.possible_deps:
                    if dep_name != dep["name"]:
                        continue

                    dep_feature_resolutions = dep["feature_resolutions"]
                    if dep.get("kind", "normal") == "build":
                        dep_triples = dependency_resolution_triples(
                            dep,
                            dep_feature_resolutions.is_proc_macro,
                            triple,
                            exec_triples,
                            feature_set,
                            cfg_attrs_by_triple,
                        )
                        if not dep_triples:
                            continue
                    elif not _dep_target_matches_triple(dep, triple, feature_set, cfg_attrs_by_triple):
                        continue

                    found = True
                    dep_optional = dep.get("optional", False)
                    if not optional_marker or not dep_optional or dep_name in feature_set or ("dep:" + dep_name) in feature_set:
                        if apply_dependency_edge(
                            dep,
                            dep_feature_resolutions,
                            triple,
                            exec_triples,
                            feature_set,
                            cfg_attrs_by_triple,
                            features = [dep_feature],
                        ):
                            dirty_package_indices.add(dep_feature_resolutions.package_index)
                    break

                # Only optional deps need to be explicitly enabled when a subfeature is toggled.
                if dep_optional and (not optional_marker) and dep_name not in feature_set:
                    package_changed = True
                    feature_set.add(dep_name)

                if not found and debug:
                    print("Skipping enabling subfeature", feature, "for", package["name"], "@", package["version"], "it's not a dep...")

    return package_changed

_MAX_ROUNDS = 200

def resolve(mctx, packages, feature_resolutions_by_fq_crate, cfg_attrs_by_triple, debug, exec_triples):
    # Do some rounds of mutual resolution; bail when no more changes
    dirty_package_indices = range(len(packages))

    for i in range(_MAX_ROUNDS):
        if mctx:
            mctx.report_progress("Running round %s of dependency/feature resolution" % i)

        dirty_package_indices = _resolve_one_round(packages, dirty_package_indices, cfg_attrs_by_triple, debug, exec_triples)
        if not dirty_package_indices:
            if debug:
                count = _count(feature_resolutions_by_fq_crate)
                print("Got count", count, "in", i + 1, "rounds")
            break
        dirty_package_indices = sorted(dirty_package_indices)

    if dirty_package_indices:
        fail("Resolution did not converge after %s rounds! This is likely a bug in rules_rs, please report it to github.com/hermeticbuild/rules_rs" % _MAX_ROUNDS)
