#!/usr/bin/env bash
#
# Render k3d/authn.yaml.tmpl into a complete AuthenticationConfiguration.
#
#   render-authn.sh <users.yaml> <ca.crt> <template> <output>
#
# Two placeholders are replaced, both on a line of their own so the
# surrounding indentation is reproduced for the multi-line value:
#
#   __CA_PEM__      -> the CA certificate as a YAML block scalar
#   __GROUPS_MAP__  -> a CEL expression mapping claims.email to its group list
#
set -euo pipefail

USERS=${1:?users.yaml required}
CA=${2:?ca.crt required}
TMPL=${3:?template required}
OUT=${4:?output path required}

command -v yq >/dev/null || { echo "render-authn: yq is required" >&2; exit 1; }
for f in "$USERS" "$CA" "$TMPL"; do
  [ -r "$f" ] || { echo "render-authn: cannot read $f" >&2; exit 1; }
done

# {'alice@team-a.local': ['team-a:dev'], 'bob@team-a.local': ['team-a:admin'], ...}
cel_map() {
  yq -r '
    "{" +
    ([.users[] | "'\''" + .email + "'\'': [" +
       ([.groups[] | "'\''" + . + "'\''"] | join(", ")) + "]"] | join(", ")) +
    "}"
  ' "$USERS"
}

MAP=$(cel_map)
[ "$MAP" != "{}" ] || { echo "render-authn: $USERS lists no users" >&2; exit 1; }

# CEL has no safe map lookup without the optional library, so the map is
# emitted twice: once as a membership test, once as the subscript.
EXPR="claims.email in ${MAP} ? ${MAP}[claims.email] : []"

mkdir -p "$(dirname "$OUT")"
TMP=$(mktemp "${OUT}.XXXXXX")
trap 'rm -f "$TMP"' EXIT

while IFS= read -r line; do
  indent=${line%%[![:space:]]*}
  case $line in
    *__CA_PEM__*)
      printf '%s|\n' "${line%%__CA_PEM__*}"
      sed "s/^/${indent}  /" "$CA"
      ;;
    *__GROUPS_MAP__*)
      printf '%s>-\n' "${line%%__GROUPS_MAP__*}"
      printf '%s  %s\n' "$indent" "$EXPR"
      ;;
    *)
      printf '%s\n' "$line"
      ;;
  esac
done < "$TMPL" > "$TMP"

mv "$TMP" "$OUT"
chmod go-rwx "$OUT"
echo "==> Wrote $OUT (issuer $(yq -r '.jwt[0].issuer.url' "$OUT"), $(yq '.users | length' "$USERS") users)"
