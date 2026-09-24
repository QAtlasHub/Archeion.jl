```@meta
CurrentModule = Archeion
```

# API References

What a caller needs, grouped by when they need it. Everything else in the module is an internal
detail and may move between patch releases.

Two names are exported — [`deposit`](@ref) and [`new_binding`](@ref) — because they are the two a
study script calls. The rest are reached as `Archeion.…`, which keeps a registry script explicit
about what it is doing.

## Starting a registry

```@docs
init
setup_pages
default_branch
```

## Putting a result in

```@docs
new_binding
deposit
publish
doc_fields
```

## Checking and reading

```@docs
validate
reindex!
build
check_settled
```

## Talking to the remote

```@docs
sync!
publish_revision!
check_source_published
rebase_onto_remote!
```

## Converting a `registry/1` tree

```@docs
migrate!
```

## Provenance

```@docs
write_provenance!
provenance_from
```

## The command line

```@docs
main
```
