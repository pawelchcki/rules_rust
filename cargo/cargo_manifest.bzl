"""Aspect that generates Cargo.toml files from BUILD files, which is useful
for interacting with vanilla Rust tooling.
"""

load("//rust/private:providers.bzl", "CrateInfo")
load("//rust/private:utils.bzl", "relativize")

CargoManifestInfo = provider(
    doc = "A provider contianing information about a Crate's cargo metadata.",
    fields = {
        "toml": "The current crate's Cargo.toml file.",
        "deps": "The Cargo.toml files the current crate depends on.",
    },
)

def _output_dir(ctx):
    """Returns the output directory the aspect should write into.

    Args:
        ctx (ctx): The current aspect's context object

    Returns:
        string: The output directory name for the current aspect
    """
    return "cargo_manifest.aspect/{}".format(ctx.rule.attr.name)

def _is_external_crate(target):
    """Returns whether or not the target is an external target.

    eg: `@bazel_skylib//:lib` is an external target where as `@rules_rust//:lib` or `//:lib` are not.

    Args:
        target (Target): The target the aspect is being applied to.

    Returns:
        bool: True if the target is an external target
    """
    return target.label.workspace_root.startswith("external")

def _clone_external_crate_sources(ctx, target):
    """Creates copies of the source files for external crates.

    This is done to ensure manifests generated for external targets can always refer to it's source code via
    some predictable path.

    Args:
        ctx (ctx): The current aspect's context object
        target (Target): The target the aspect is being applied to.

    Returns:
        tuple: A tuple of the following items:
            - (list): A list of `File`s created by this macro
            - (File): The generated file matching `target`'s crate root.
    """
    if not _is_external_crate(target):
        fail("{} is not an external target".format(target.label))

    crate_info = target[CrateInfo]
    outputs = []
    copy_commands = []
    root = None
    for src in crate_info.srcs.to_list():
        # Get the path from the root of `external`

        external_crate_short_path = src.short_path[len("../"):]

        output = ctx.actions.declare_file("{}/{}".format(_output_dir(ctx), external_crate_short_path))

        outputs.append(output)
        copy_commands.append("mkdir -p {} ; cp {} {}".format(
            output.dirname,
            src.path,
            output.path,
        ))
        if src.path == crate_info.root.path:
            root = output

    ctx.actions.run_shell(
        outputs = outputs,
        inputs = crate_info.srcs,
        command = "\n".join(copy_commands),
    )

    return outputs, root

_CARGO_MANIFEST_TEMPLATE = """\
# Generated by `cargo_manifest_aspect` from `{target_label}` in `{build_file_path}`
[package]
name = "{name}"
version = "{version}"
edition = "{edition}"

{crate_type}
name = "{name}"
path = "{path}"

[dependencies]
{dependencies}
"""

def _cargo_manifest_aspect_impl(target, ctx):
    """Creates a separate Cargo.toml for each instance of a rust rule.

    Relies on a separate step to create the workspace Cargo.toml that makes use of them.

    Args:
        target (Target): The target the aspect is being applied to.
        ctx (ctx): The current aspect's context object

    Returns:
        list: A list of providers
            - (CargoManifestInfo): Information about the current target
            - (OutputGroupInfo): A provider that indicates what output groups a rule has.
    """
    rule = ctx.rule
    library_kinds = ["rust_library", "rust_shared_library", "rust_static_library"]
    if not rule.kind in library_kinds + ["rust_binary"]:
        return []

    manifest = ctx.actions.declare_file("{}/Cargo.toml".format(_output_dir(ctx)))
    rust_deps = [dep for dep in rule.attr.deps if CrateInfo in dep]

    # TODO: This split should not be necessary but in order to define external crate roots
    # via a relative path, the source for the external crate is coped into the output
    # directory.
    if _is_external_crate(target):
        srcs, root_src = _clone_external_crate_sources(ctx, target)
    else:
        srcs = []
        root_src = target[CrateInfo].root

    ctx.actions.write(
        output = manifest,
        content = _CARGO_MANIFEST_TEMPLATE.format(
            target_label = target.label,
            build_file_path = ctx.build_file_path,
            crate_type = "[lib]" if rule.kind in library_kinds else "[[bin]]",
            name = target.label.name,
            version = rule.attr.version,
            edition = target[CrateInfo].edition,
            path = relativize(root_src.path, manifest.dirname),
            dependencies = "\n".join([
                "{} = {{ path = \"{}\" }}".format(dep.label.name, relativize(dep[CargoManifestInfo].toml.dirname, manifest.dirname))
                for dep in rust_deps
            ]),
        ),
    )

    deps = [dep[OutputGroupInfo].all_files for dep in rust_deps]

    return [
        CargoManifestInfo(
            toml = manifest,
            deps = depset(transitive = deps),
        ),
        OutputGroupInfo(
            all_files = depset([manifest], transitive = deps + [depset(srcs)]),
        ),
    ]

cargo_manifest_aspect = aspect(
    doc = "An aspect that generates Cargo metadata (Cargo.toml files) for `rust_binary` and `rust_library` targets.",
    attr_aspects = ["deps"],
    implementation = _cargo_manifest_aspect_impl,
    toolchains = [
        "@rules_rust//rust:toolchain",
    ],
)