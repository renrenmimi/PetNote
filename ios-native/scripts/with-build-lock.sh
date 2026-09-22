#!/bin/bash
# 一次只许一项重型构建或测试跑（这台 Mac 16GB）。
#
# 用法：bash scripts/with-build-lock.sh <要跑的命令…>
#
# 用 mkdir 做锁：它在 POSIX 上是原子的，flock 在 macOS 上不是自带的。
# 锁里写进 PID 和命令，这样卡住时能看出是谁占着，而不是只看到一个空目录。
LOCK="${TMPDIR:-/tmp}/petnote-heavy-build.lock"
WAITED=0
LIMIT="${BUILD_LOCK_TIMEOUT:-5400}"

while ! mkdir "$LOCK" 2>/dev/null; do
    HOLDER=$(cat "$LOCK/owner" 2>/dev/null || echo "未知")
    HOLDER_PID=$(cat "$LOCK/pid" 2>/dev/null || echo "")
    # 持有者已经死了就接管，否则一次崩溃会把锁永远留下。
    if [ -n "$HOLDER_PID" ] && ! kill -0 "$HOLDER_PID" 2>/dev/null; then
        echo "锁的持有者 $HOLDER_PID 已不在，接管" >&2
        rm -rf "$LOCK"
        continue
    fi
    if [ "$WAITED" -ge "$LIMIT" ]; then
        echo "等了 ${LIMIT}s 仍拿不到构建锁，持有者：$HOLDER" >&2
        exit 75   # EX_TEMPFAIL：是没排上队，不是构建失败
    fi
    [ $((WAITED % 60)) -eq 0 ] && echo "排队中（${WAITED}s），前面是：$HOLDER" >&2
    sleep 5
    WAITED=$((WAITED + 5))
done

echo "$$" > "$LOCK/pid"
echo "$*" > "$LOCK/owner"
trap 'rm -rf "$LOCK"' EXIT INT TERM

"$@"
