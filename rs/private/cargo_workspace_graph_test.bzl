load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":cargo_workspace_graph.bzl", "cargo_toml_dependencies", "cargo_toml_fact", "compute_package_fq_deps", "exec_compatible_triples", "new_feature_resolutions", "registry_crate_kind_candidates", "resolve_cargo_workspace_members", "resolve_package_facts", "select_package_fq_dep", "split_lockfile_packages", "workspace_dep_data")
load(":cfg_parser.bzl", "triple_to_cfg_attrs")
load(":resolver.bzl", "resolve")

def _select_package_fq_dep_uses_package_name_impl(ctx):
    env = unittest.begin(ctx)

    got = select_package_fq_dep(
        {
            "name": "alloc",
            "package": "rustc-std-workspace-alloc",
            "req": "1.0.0",
        },
        {
            "rustc-std-workspace-alloc": ["rustc-std-workspace-alloc-1.99.0"],
        },
    )

    asserts.equals(env, "rustc-std-workspace-alloc-1.99.0", got)
    return unittest.end(env)

def _select_package_fq_dep_uses_req_for_duplicate_versions_impl(ctx):
    env = unittest.begin(ctx)

    fq_deps = compute_package_fq_deps(
        {
            "dependencies": [
                "wasi 0.11.1+wasi-snapshot-preview1",
                "wasi 0.14.4+wasi-0.2.4",
            ],
        },
        {},
    )

    got_wasi = select_package_fq_dep(
        {
            "name": "wasi",
            "req": "0.11.0",
        },
        fq_deps,
    )
    got_wasip2 = select_package_fq_dep(
        {
            "name": "wasip2",
            "package": "wasi",
            "req": "0.14.4",
        },
        fq_deps,
    )

    asserts.equals(env, "wasi-0.11.1+wasi-snapshot-preview1", got_wasi)
    asserts.equals(env, "wasi-0.14.4+wasi-0.2.4", got_wasip2)
    return unittest.end(env)

select_package_fq_dep_uses_package_name_test = unittest.make(_select_package_fq_dep_uses_package_name_impl)
select_package_fq_dep_uses_req_for_duplicate_versions_test = unittest.make(_select_package_fq_dep_uses_req_for_duplicate_versions_impl)

def _cargo_toml_dependencies_normalizes_dependency_specs_impl(ctx):
    env = unittest.begin(ctx)

    got = cargo_toml_dependencies(
        {
            "package": {
                "name": "test",
            },
            "dependencies": {
                "alloc": {
                    "features": ["serde"],
                    "package": "rustc-std-workspace-alloc",
                    "path": "../rustc-std-workspace-alloc",
                    "version": "1.0.0",
                },
                "serde": "1",
            },
            "build-dependencies": {
                "cc": "1",
            },
            "target": {
                "cfg(windows)": {
                    "build-dependencies": {
                        "windows-resource": {
                            "version": "1",
                        },
                    },
                    "dependencies": {
                        "windows-sys": {
                            "version": "1",
                        },
                    },
                },
            },
        },
    )

    asserts.equals(env, [
        {
            "default_features": True,
            "features": ["serde"],
            "name": "alloc",
            "optional": False,
            "package": "rustc-std-workspace-alloc",
            "req": "1.0.0",
        },
        {
            "name": "serde",
            "req": "1",
        },
        {
            "kind": "build",
            "name": "cc",
            "req": "1",
        },
        {
            "default_features": True,
            "features": [],
            "name": "windows-sys",
            "optional": False,
            "req": "1",
            "target": "cfg(windows)",
        },
        {
            "default_features": True,
            "features": [],
            "kind": "build",
            "name": "windows-resource",
            "optional": False,
            "req": "1",
            "target": "cfg(windows)",
        },
    ], got)
    return unittest.end(env)

cargo_toml_dependencies_normalizes_dependency_specs_test = unittest.make(_cargo_toml_dependencies_normalizes_dependency_specs_impl)

def _cargo_toml_dependencies_handles_workspace_inheritance_impl(ctx):
    env = unittest.begin(ctx)

    got = cargo_toml_dependencies(
        {
            "package": {
                "name": "test",
            },
            "dependencies": {
                "serde": {
                    "features": ["derive"],
                    "workspace": True,
                },
            },
        },
        {
            "workspace": {
                "dependencies": {
                    "serde": {
                        "default-features": False,
                        "features": ["alloc"],
                        "version": "1.0.0",
                    },
                },
            },
        },
    )

    asserts.equals(env, [
        {
            "default_features": False,
            "features": ["alloc", "derive"],
            "name": "serde",
            "optional": False,
            "req": "1.0.0",
        },
    ], got)
    return unittest.end(env)

cargo_toml_dependencies_handles_workspace_inheritance_test = unittest.make(_cargo_toml_dependencies_handles_workspace_inheritance_impl)

def _split_lockfile_packages_finds_local_package_paths_impl(ctx):
    env = unittest.begin(ctx)

    got = split_lockfile_packages(
        hub_name = "hub",
        cargo_metadata = {
            "packages": [
                {
                    "dependencies": [
                        {
                            "name": "path-dep",
                            "path": "/repo/crates/path-dep",
                        },
                    ],
                    "manifest_path": "/repo/root/Cargo.toml",
                    "name": "root",
                    "version": "0.1.0",
                },
            ],
        },
        all_packages = [
            {
                "name": "root",
                "version": "0.1.0",
            },
            {
                "name": "path-dep",
                "version": "1.0.0",
            },
            {
                "name": "patched-crate",
                "version": "1.0.0",
            },
            {
                "name": "serde",
                "source": "sparse+https://index.crates.io/",
                "version": "1.0.0",
            },
        ],
        workspace_cargo_toml = {
            "patch": {
                "crates-io": {
                    "patched": {
                        "package": "patched-crate",
                        "path": "vendor/patched",
                    },
                },
            },
        },
        repo_root = "/repo",
    )

    asserts.equals(env, [
        {
            "name": "root",
            "version": "0.1.0",
        },
    ], got.workspace_members)
    asserts.equals(env, [
        {
            "local_path": "/repo/crates/path-dep",
            "name": "path-dep",
            "source": "path+hub/crates/path-dep",
            "version": "1.0.0",
        },
        {
            "local_path": "/repo/vendor/patched",
            "name": "patched-crate",
            "source": "path+hub/vendor/patched",
            "version": "1.0.0",
        },
        {
            "name": "serde",
            "source": "sparse+https://index.crates.io/",
            "version": "1.0.0",
        },
    ], got.packages)
    return unittest.end(env)

split_lockfile_packages_finds_local_package_paths_test = unittest.make(_split_lockfile_packages_finds_local_package_paths_impl)

def _resolve_package_facts_attaches_feature_resolutions_impl(ctx):
    env = unittest.begin(ctx)

    packages = [
        {
            "name": "serde",
            "version": "1.0.0",
        },
    ]
    got = resolve_package_facts(
        packages,
        {
            "serde-1.0.0": {
                "dependencies": [
                    {
                        "name": "serde_derive",
                        "optional": True,
                    },
                ],
                "features": {
                    "derive": ["dep:serde_derive"],
                },
            },
        },
        ["x86_64-unknown-linux-gnu"],
    )

    asserts.equals(env, {"serde": ["1.0.0"]}, got.versions_by_name)
    asserts.true(env, "feature_resolutions" in packages[0])
    asserts.equals(env, ["serde-1.0.0"], got.feature_resolutions_by_fq_crate.keys())
    return unittest.end(env)

resolve_package_facts_attaches_feature_resolutions_test = unittest.make(_resolve_package_facts_attaches_feature_resolutions_impl)

def _cargo_toml_fact_detects_proc_macro_impl(ctx):
    env = unittest.begin(ctx)

    fact = cargo_toml_fact({
        "dependencies": {},
        "features": {},
        "lib": {"proc-macro": True},
        "package": {"name": "derive-helper"},
    })

    asserts.true(env, fact["is_proc_macro"])
    asserts.true(env, cargo_toml_fact({
        "dependencies": {},
        "features": {},
        "lib": {"crate-type": ["proc-macro"]},
        "package": {"name": "derive-helper"},
    })["is_proc_macro"])
    return unittest.end(env)

cargo_toml_fact_detects_proc_macro_test = unittest.make(_cargo_toml_fact_detects_proc_macro_impl)

def _exec_compatible_triples_requires_exact_triple_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        ["aarch64-apple-darwin", "x86_64-unknown-linux-gnu"],
        sorted(exec_compatible_triples([
            "aarch64-apple-darwin",
            "wasm32-unknown-unknown",
            "x86_64-pc-windows-gnullvm",
            "x86_64-unknown-linux-gnu",
        ])),
    )
    asserts.equals(
        env,
        [],
        sorted(exec_compatible_triples([
            "x86_64-pc-windows-gnullvm",
            "x86_64-unknown-linux-musl",
        ])),
    )
    return unittest.end(env)

exec_compatible_triples_requires_exact_triple_test = unittest.make(_exec_compatible_triples_requires_exact_triple_impl)

def _resolve_preserves_build_dependency_host_filters_impl(ctx):
    env = unittest.begin(ctx)

    linux = "x86_64-unknown-linux-gnu"
    macos = "aarch64-apple-darwin"
    windows = "x86_64-pc-windows-msvc"
    triples = [linux, macos, windows]
    packages = [
        {
            "dependencies": [],
            "name": "host-helper",
            "version": "1.0.0",
        },
        {
            "dependencies": ["host-helper 1.0.0"],
            "name": "consumer",
            "version": "1.0.0",
        },
    ]
    package_resolution = resolve_package_facts(
        packages,
        {
            "consumer-1.0.0": {
                "dependencies": [
                    {
                        "default_features": True,
                        "features": ["windows-backend"],
                        "kind": "build",
                        "name": "host-helper",
                        "target": "cfg(windows)",
                    },
                ],
                "features": {
                    "forward-build-feature": ["host-helper/forwarded"],
                },
            },
            "host-helper-1.0.0": {
                "dependencies": [],
                "features": {
                    "default": [],
                    "forwarded": [],
                    "windows-backend": [],
                },
            },
        },
        triples,
    )

    resolve_cargo_workspace_members(
        None,
        cargo_metadata = {"packages": []},
        packages = packages,
        workspace_members = [],
        versions_by_name = package_resolution.versions_by_name,
        feature_resolutions_by_fq_crate = package_resolution.feature_resolutions_by_fq_crate,
        annotations = {
            "consumer": {
                "*": struct(
                    crate_features = ["forward-build-feature"],
                    crate_features_select = {},
                ),
            },
        },
        platform_triples = triples,
        materialize_workspace_members = False,
        validate_lockfile = False,
    )

    consumer = package_resolution.feature_resolutions_by_fq_crate["consumer-1.0.0"]
    host_helper = package_resolution.feature_resolutions_by_fq_crate["host-helper-1.0.0"]
    asserts.equals(env, [], sorted(consumer.build_deps[linux]))
    asserts.equals(env, [], sorted(consumer.build_deps[macos]))
    asserts.equals(env, ["//:host-helper-1.0.0"], sorted(consumer.build_deps[windows]))
    asserts.equals(env, [], sorted(host_helper.features_enabled[linux]))
    asserts.equals(env, [], sorted(host_helper.features_enabled[macos]))
    asserts.equals(env, ["default", "forwarded", "windows-backend"], sorted(host_helper.features_enabled[windows]))
    return unittest.end(env)

resolve_preserves_build_dependency_host_filters_test = unittest.make(_resolve_preserves_build_dependency_host_filters_impl)

def _resolve_maps_target_feature_gated_build_dependency_to_exec_impl(ctx):
    env = unittest.begin(ctx)

    linux = "x86_64-unknown-linux-gnu"
    wasm = "wasm32-unknown-unknown"
    triples = [linux, wasm]
    packages = [
        {
            "dependencies": [],
            "name": "host-helper",
            "version": "1.0.0",
        },
        {
            "dependencies": ["host-helper 1.0.0"],
            "name": "consumer",
            "version": "1.0.0",
        },
    ]
    package_resolution = resolve_package_facts(
        packages,
        {
            "consumer-1.0.0": {
                "dependencies": [
                    {
                        "default_features": False,
                        "features": ["helper-api"],
                        "kind": "build",
                        "name": "host-helper",
                        "optional": True,
                    },
                ],
                "features": {
                    "use-host-helper": [
                        "dep:host-helper",
                        "host-helper/forwarded",
                    ],
                },
            },
            "host-helper-1.0.0": {
                "dependencies": [],
                "features": {
                    "forwarded": [],
                    "helper-api": [],
                },
            },
        },
        triples,
    )

    resolve_cargo_workspace_members(
        None,
        cargo_metadata = {"packages": []},
        packages = packages,
        workspace_members = [],
        versions_by_name = package_resolution.versions_by_name,
        feature_resolutions_by_fq_crate = package_resolution.feature_resolutions_by_fq_crate,
        annotations = {
            "consumer": {
                "*": struct(
                    crate_features = [],
                    crate_features_select = {
                        wasm: ["use-host-helper"],
                    },
                ),
            },
        },
        platform_triples = triples,
        materialize_workspace_members = False,
        validate_lockfile = False,
    )

    consumer = package_resolution.feature_resolutions_by_fq_crate["consumer-1.0.0"]
    host_helper = package_resolution.feature_resolutions_by_fq_crate["host-helper-1.0.0"]
    asserts.equals(env, ["//:host-helper-1.0.0"], sorted(consumer.build_deps[linux]))
    asserts.equals(env, [], sorted(consumer.build_deps[wasm]))
    asserts.equals(env, ["forwarded", "helper-api"], sorted(host_helper.features_enabled[linux]))
    asserts.equals(env, [], sorted(host_helper.features_enabled[wasm]))
    return unittest.end(env)

resolve_maps_target_feature_gated_build_dependency_to_exec_test = unittest.make(_resolve_maps_target_feature_gated_build_dependency_to_exec_impl)

def _workspace_dep_data_maps_target_feature_gated_build_dependency_to_exec_impl(ctx):
    env = unittest.begin(ctx)

    linux = "x86_64-unknown-linux-gnu"
    wasm = "wasm32-unknown-unknown"
    triples = [linux, wasm]
    feature_resolutions = new_feature_resolutions(0, [], {}, triples)
    feature_resolutions.features_enabled[wasm].add("dep:host-helper")
    platform_cfg_attrs = [triple_to_cfg_attrs(triple) for triple in triples]

    dep_data = workspace_dep_data(
        cargo_metadata = {
            "packages": [
                {
                    "dependencies": [
                        {
                            "bazel_target": "@crates//:host-helper-1.0.0",
                            "kind": "build",
                            "name": "host-helper",
                            "optional": True,
                            "target": None,
                        },
                    ],
                    "manifest_path": "/workspace/Cargo.toml",
                    "name": "consumer",
                    "targets": [],
                    "version": "1.0.0",
                },
            ],
        },
        feature_resolutions_by_fq_crate = {
            "consumer-1.0.0": feature_resolutions,
        },
        platform_triples = triples,
        platform_cfg_attrs = platform_cfg_attrs,
        cfg_match_cache = {None: struct(matches = triples, uses_feature_cfg = False)},
        repo_root = "/workspace",
        workspace_package = "",
        use_legacy_rules_rust_platforms = False,
    )[""]

    asserts.equals(env, [], dep_data["build_deps"])
    asserts.equals(
        env,
        {
            "@rules_rs//rs/platforms/config:" + linux: ["@crates//:host-helper-1.0.0"],
        },
        dep_data["build_deps_by_platform"],
    )
    return unittest.end(env)

workspace_dep_data_maps_target_feature_gated_build_dependency_to_exec_test = unittest.make(_workspace_dep_data_maps_target_feature_gated_build_dependency_to_exec_impl)

def _resolve_confines_proc_macro_dependency_graph_to_exec_impl(ctx):
    env = unittest.begin(ctx)

    linux = "x86_64-unknown-linux-gnu"
    wasm = "wasm32-unknown-unknown"
    triples = [linux, wasm]
    packages = [
        {
            "dependencies": [],
            "name": "host-leaf",
            "version": "1.0.0",
        },
        {
            "dependencies": ["host-leaf 1.0.0"],
            "name": "derive-helper",
            "version": "1.0.0",
        },
    ]
    package_resolution = resolve_package_facts(
        packages,
        {
            "derive-helper-1.0.0": {
                "dependencies": [
                    {
                        "default_features": False,
                        "features": ["host-api"],
                        "name": "host-leaf",
                    },
                ],
                "features": {
                    "common": [],
                    "target-selected": [],
                },
                "is_proc_macro": True,
            },
            "host-leaf-1.0.0": {
                "dependencies": [],
                "features": {"host-api": []},
            },
        },
        triples,
    )

    resolve_cargo_workspace_members(
        None,
        cargo_metadata = {"packages": []},
        packages = packages,
        workspace_members = [],
        versions_by_name = package_resolution.versions_by_name,
        feature_resolutions_by_fq_crate = package_resolution.feature_resolutions_by_fq_crate,
        annotations = {
            "derive-helper": {
                "*": struct(
                    crate_features = ["common"],
                    crate_features_select = {
                        wasm: ["target-selected"],
                    },
                ),
            },
        },
        platform_triples = triples,
        materialize_workspace_members = False,
        validate_lockfile = False,
    )

    derive_helper = package_resolution.feature_resolutions_by_fq_crate["derive-helper-1.0.0"]
    host_leaf = package_resolution.feature_resolutions_by_fq_crate["host-leaf-1.0.0"]
    asserts.equals(env, ["common", "target-selected"], sorted(derive_helper.features_enabled[linux]))
    asserts.equals(env, [], sorted(derive_helper.features_enabled[wasm]))
    asserts.equals(env, ["//:host-leaf-1.0.0"], sorted(derive_helper.deps[linux]))
    asserts.equals(env, [], sorted(derive_helper.deps[wasm]))
    asserts.equals(env, ["host-api"], sorted(host_leaf.features_enabled[linux]))
    asserts.equals(env, [], sorted(host_leaf.features_enabled[wasm]))
    return unittest.end(env)

resolve_confines_proc_macro_dependency_graph_to_exec_test = unittest.make(_resolve_confines_proc_macro_dependency_graph_to_exec_impl)

def _resolve_registry_proc_macro_features_for_exec_triples_impl(ctx):
    env = unittest.begin(ctx)

    linux = "x86_64-unknown-linux-gnu"
    windows = "x86_64-pc-windows-gnullvm"
    triples = [linux, windows]
    facts = {
        "consumer-1.0.0": {
            "dependencies": [
                {
                    "default_features": False,
                    "features": ["target-api"],
                    "name": "derive-helper",
                    "target": "cfg(windows)",
                },
            ],
            "features": {},
        },
        "derive-helper-1.0.0": {
            "dependencies": [],
            "features": {"target-api": []},
        },
    }
    packages = [
        {
            "dependencies": [],
            "name": "derive-helper",
            "source": "sparse+https://index.crates.io/",
            "version": "1.0.0",
        },
        {
            "dependencies": ["derive-helper 1.0.0"],
            "name": "consumer",
            "source": "sparse+https://index.crates.io/",
            "version": "1.0.0",
        },
    ]
    package_resolution = resolve_package_facts(packages, facts, triples)
    resolve_cargo_workspace_members(
        None,
        cargo_metadata = {"packages": []},
        packages = packages,
        workspace_members = [],
        versions_by_name = package_resolution.versions_by_name,
        feature_resolutions_by_fq_crate = package_resolution.feature_resolutions_by_fq_crate,
        annotations = {},
        platform_triples = triples,
        materialize_workspace_members = False,
        validate_lockfile = False,
    )

    derive_helper = package_resolution.feature_resolutions_by_fq_crate["derive-helper-1.0.0"]
    asserts.equals(env, [], sorted(derive_helper.features_enabled[linux]))
    asserts.equals(env, ["target-api"], sorted(derive_helper.features_enabled[windows]))
    asserts.equals(
        env,
        ["derive-helper"],
        [package["name"] for package in registry_crate_kind_candidates(packages, facts, triples)],
    )

    facts["derive-helper-1.0.0"]["is_proc_macro"] = True
    packages = [
        {
            "dependencies": [],
            "name": "derive-helper",
            "source": "sparse+https://index.crates.io/",
            "version": "1.0.0",
        },
        {
            "dependencies": ["derive-helper 1.0.0"],
            "name": "consumer",
            "source": "sparse+https://index.crates.io/",
            "version": "1.0.0",
        },
    ]
    package_resolution = resolve_package_facts(packages, facts, triples)
    resolve_cargo_workspace_members(
        None,
        cargo_metadata = {"packages": []},
        packages = packages,
        workspace_members = [],
        versions_by_name = package_resolution.versions_by_name,
        feature_resolutions_by_fq_crate = package_resolution.feature_resolutions_by_fq_crate,
        annotations = {},
        platform_triples = triples,
        materialize_workspace_members = False,
        validate_lockfile = False,
    )

    derive_helper = package_resolution.feature_resolutions_by_fq_crate["derive-helper-1.0.0"]
    asserts.equals(env, ["target-api"], sorted(derive_helper.features_enabled[linux]))
    asserts.equals(env, [], sorted(derive_helper.features_enabled[windows]))
    asserts.equals(env, [], registry_crate_kind_candidates(packages, facts, triples))
    return unittest.end(env)

resolve_registry_proc_macro_features_for_exec_triples_test = unittest.make(_resolve_registry_proc_macro_features_for_exec_triples_impl)

def _resolve_keeps_public_aliases_buildable_outside_cargo_target_impl(ctx):
    env = unittest.begin(ctx)

    native = "x86_64-unknown-linux-gnu"
    windows = "x86_64-pc-windows-gnullvm"
    triples = [native, windows]
    packages = [
        {
            "dependencies": [],
            "name": "leaf",
            "version": "1.0.0",
        },
        {
            "dependencies": ["leaf 1.0.0"],
            "name": "platform-only",
            "version": "1.0.0",
        },
        {
            "dependencies": [],
            "name": "support",
            "version": "1.0.0",
        },
        {
            "dependencies": ["platform-only 1.0.0", "support 1.0.0"],
            "name": "conditional",
            "version": "1.0.0",
        },
    ]
    package_resolution = resolve_package_facts(
        packages,
        {
            "conditional-1.0.0": {
                "dependencies": [
                    {
                        "default_features": False,
                        "name": "platform-only",
                        "target": "cfg(windows)",
                    },
                    {
                        "default_features": False,
                        "features": ["platform-api"],
                        "name": "support",
                    },
                ],
                "features": {
                    "root-api": [],
                },
            },
            "leaf-1.0.0": {
                "dependencies": [],
                "features": {},
            },
            "platform-only-1.0.0": {
                "dependencies": [
                    {
                        "default_features": False,
                        "name": "leaf",
                    },
                ],
                "features": {},
            },
            "support-1.0.0": {
                "dependencies": [],
                "features": {
                    "platform-api": [],
                },
            },
        },
        triples,
    )

    resolve_cargo_workspace_members(
        None,
        cargo_metadata = {
            "packages": [
                {
                    "dependencies": [
                        {
                            "features": ["root-api"],
                            "kind": "normal",
                            "name": "conditional",
                            "optional": False,
                            "req": "1",
                            "source": "registry+https://github.com/rust-lang/crates.io-index",
                            "target": "cfg(not(windows))",
                            "uses_default_features": False,
                        },
                    ],
                    "features": {},
                    "manifest_path": "/workspace/Cargo.toml",
                    "name": "root",
                    "version": "0.1.0",
                },
            ],
        },
        packages = packages,
        workspace_members = [
            {
                "dependencies": ["conditional 1.0.0"],
                "name": "root",
                "version": "0.1.0",
            },
        ],
        versions_by_name = package_resolution.versions_by_name,
        feature_resolutions_by_fq_crate = package_resolution.feature_resolutions_by_fq_crate,
        annotations = {},
        platform_triples = triples,
        materialize_workspace_members = False,
        validate_lockfile = False,
    )

    conditional = package_resolution.feature_resolutions_by_fq_crate["conditional-1.0.0"]
    leaf = package_resolution.feature_resolutions_by_fq_crate["leaf-1.0.0"]
    platform_only = package_resolution.feature_resolutions_by_fq_crate["platform-only-1.0.0"]
    support = package_resolution.feature_resolutions_by_fq_crate["support-1.0.0"]
    root = package_resolution.feature_resolutions_by_fq_crate["root-0.1.0"]
    asserts.equals(env, ["//:conditional-1.0.0"], sorted(root.deps[native]))
    asserts.equals(env, [], sorted(root.deps[windows]))
    asserts.equals(env, ["root-api"], sorted(conditional.features_enabled[native]))
    asserts.equals(env, [], sorted(conditional.features_enabled[windows]))
    asserts.equals(env, ["//:platform-only-1.0.0", "//:support-1.0.0"], sorted(conditional.deps[windows]))
    asserts.equals(env, ["platform-api"], sorted(support.features_enabled[windows]))
    asserts.equals(env, ["//:leaf-1.0.0"], sorted(platform_only.deps[native]))
    asserts.equals(env, ["//:leaf-1.0.0"], sorted(platform_only.deps[windows]))
    asserts.equals(env, [], sorted(leaf.deps[native]))
    return unittest.end(env)

resolve_keeps_public_aliases_buildable_outside_cargo_target_test = unittest.make(_resolve_keeps_public_aliases_buildable_outside_cargo_target_impl)

def _resolve_package_facts_preserves_persisted_dependency_features_impl(ctx):
    env = unittest.begin(ctx)

    facts = {
        "consumer-1.0.0": {
            "dependencies": [
                {
                    "default_features": True,
                    "features": ["derive"],
                    "name": "helper",
                },
            ],
            "features": {},
        },
        "helper-1.0.0": {
            "dependencies": [],
            "features": {},
        },
    }
    packages = [
        {
            "dependencies": ["helper 1.0.0"],
            "name": "consumer",
            "version": "1.0.0",
        },
        {
            "dependencies": [],
            "name": "helper",
            "version": "1.0.0",
        },
    ]

    first = resolve_package_facts(packages, facts, ["x86_64-unknown-linux-gnu"])
    resolve_package_facts([dict(package) for package in packages], facts, ["x86_64-unknown-linux-gnu"])

    asserts.equals(env, ["derive"], facts["consumer-1.0.0"]["dependencies"][0]["features"])
    asserts.equals(
        env,
        ["derive", "default"],
        first.feature_resolutions_by_fq_crate["consumer-1.0.0"].possible_deps[0]["features"],
    )
    return unittest.end(env)

resolve_package_facts_preserves_persisted_dependency_features_test = unittest.make(_resolve_package_facts_preserves_persisted_dependency_features_impl)

def _resolve_handles_dependency_chains_deeper_than_previous_round_limit_impl(ctx):
    env = unittest.begin(ctx)

    triple = "x86_64-unknown-linux-gnu"
    triples = [triple]
    packages = []
    resolutions = []
    resolutions_by_crate = {}
    for index in range(60):
        name = "chain-%s" % index
        possible_deps = []
        if index:
            possible_deps.append({
                "bazel_target": "//:chain-%s" % (index - 1),
                "feature_resolutions": resolutions[index - 1],
                "name": "chain-%s" % (index - 1),
                "target": set(triples),
            })

        possible_features = {"forward": []}
        if index:
            possible_features["forward"] = ["chain-%s/forward" % (index - 1)]

        resolution = new_feature_resolutions(index, possible_deps, possible_features, triples)
        resolutions.append(resolution)
        resolutions_by_crate["%s-1.0.0" % name] = resolution
        packages.append({
            "feature_resolutions": resolution,
            "name": name,
            "version": "1.0.0",
        })

    resolutions[-1].features_enabled[triple].add("forward")
    resolve(None, packages, resolutions_by_crate, {}, False, set([triple]))

    asserts.true(env, "forward" in resolutions[0].features_enabled[triple])
    asserts.equals(env, ["//:chain-0"], sorted(resolutions[1].deps[triple]))
    return unittest.end(env)

resolve_handles_dependency_chains_deeper_than_previous_round_limit_test = unittest.make(_resolve_handles_dependency_chains_deeper_than_previous_round_limit_impl)

def cargo_workspace_graph_tests():
    return unittest.suite(
        "cargo_workspace_graph_tests",
        cargo_toml_dependencies_handles_workspace_inheritance_test,
        cargo_toml_dependencies_normalizes_dependency_specs_test,
        cargo_toml_fact_detects_proc_macro_test,
        exec_compatible_triples_requires_exact_triple_test,
        resolve_confines_proc_macro_dependency_graph_to_exec_test,
        resolve_handles_dependency_chains_deeper_than_previous_round_limit_test,
        resolve_keeps_public_aliases_buildable_outside_cargo_target_test,
        resolve_maps_target_feature_gated_build_dependency_to_exec_test,
        resolve_package_facts_attaches_feature_resolutions_test,
        resolve_package_facts_preserves_persisted_dependency_features_test,
        resolve_preserves_build_dependency_host_filters_test,
        resolve_registry_proc_macro_features_for_exec_triples_test,
        select_package_fq_dep_uses_package_name_test,
        select_package_fq_dep_uses_req_for_duplicate_versions_test,
        split_lockfile_packages_finds_local_package_paths_test,
        workspace_dep_data_maps_target_feature_gated_build_dependency_to_exec_test,
    )
