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

# 可选的无输出看门狗：BUILD_IDLE_LOG=<命令写入的日志>。
#
# 2026-09-22 一次变异测试挂住，xcodebuild 一小时没有新输出，一直占着锁，
# 后面所有人都在排队。日志超过 BUILD_IDLE_SECONDS（默认 600）没有新内容，
# 就先把诊断写下来——谁在跑、日志最后写到哪——再结束这次运行、释放锁。
# 只结束自己启动的那个进程（按 PID），不按名字杀任何东西。
if [ -z "${BUILD_IDLE_LOG:-}" ]; then
    "$@"
    exit $?
fi

IDLE_LIMIT="${BUILD_IDLE_SECONDS:-600}"
"$@" &
CHILD=$!
while kill -0 "$CHILD" 2>/dev/null; do
    sleep 20
    [ -f "$BUILD_IDLE_LOG" ] || continue
    AGE=$(( $(date +%s) - $(stat -f %m "$BUILD_IDLE_LOG") ))
    if [ "$AGE" -ge "$IDLE_LIMIT" ]; then
        {
            echo ""
            echo "WATCHDOG: ${AGE}s 没有新输出（上限 ${IDLE_LIMIT}s），结束这次运行"
            echo "WATCHDOG: 命令：$*"
            echo "WATCHDOG: 进程："
            ps -o pid,ppid,etime,command -p "$CHILD" 2>/dev/null
            pgrep -P "$CHILD" | while read -r kid; do ps -o pid,ppid,etime,command -p "$kid" | tail -n +2; done
            echo "WATCHDOG: 日志最后 15 行："
            tail -15 "$BUILD_IDLE_LOG"
        } >> "$BUILD_IDLE_LOG.watchdog"
        echo "WATCHDOG: ${AGE}s 无输出，已结束；诊断在 $BUILD_IDLE_LOG.watchdog" >&2
        kill -TERM "$CHILD" 2>/dev/null
        for _ in 1 2 3 4 5 6; do kill -0 "$CHILD" 2>/dev/null || break; sleep 5; done
        kill -KILL "$CHILD" 2>/dev/null
        wait "$CHILD" 2>/dev/null
        exit 124
    fi
done
wait "$CHILD"
