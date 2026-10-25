#!/usr/bin/env bash
# refusal.sh — sourced by merge.sh. merge_refusal <pull request JSON file> prints why the merge-bot must NOT
# merge this pull request, and nothing when it may (Vidocq/vidocq#285):
#   - work in progress: a WIP:/[WIP] title, a draft, or the WIP label (the maintainer's rule, also enforced by
#     the pr-validate check itself);
#   - a member of a PR train (label train-member): validated through its train's top and merged by the train
#     script after it, never on its own;
#   - the label blocked.
# The classification is pr-validate-gate/gate.py's, the one the pr-validate check uses. A pull request it
# cannot classify is refused too.

MERGE_BOT_GATE="${MERGE_BOT_GATE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../pr-validate-gate" && pwd)/gate.py}"

merge_refusal() {
  local out mode wip_reason top blocked
  if ! out=$(python3 "$MERGE_BOT_GATE" classify --pr-json "$1" 2>/dev/null); then
    echo "its title and labels cannot be read, so it is not known to be ready"
    return 0
  fi
  mode=$(sed -n 's/^mode=//p' <<<"$out")
  wip_reason=$(sed -n 's/^wip-reason=//p' <<<"$out")
  top=$(sed -n 's/^train-top=//p' <<<"$out")
  blocked=$(sed -n 's/^blocked=//p' <<<"$out")
  case "$mode" in
    train)
      echo "it is a member of a PR train (label train-member): it is validated through the train's top PR${top:+ #$top} and merged by the train script after it, never on its own" ;;
    wip)
      echo "it is work in progress (${wip_reason:-WIP}): remove WIP, let pr-validate go green, then /merge" ;;
    ready)
      if [[ "$blocked" == "true" ]]; then
        echo "it carries the label blocked: remove it first"
      fi ;;
    *)
      echo "its state cannot be read, so it is not known to be ready" ;;
  esac
}
