#!/usr/bin/env bash
# 剩余样本处置 API 端到端测试（依赖初始示例数据：
# W2026-001 1000 / W2026-002 800 / W2026-003 500；OP-0001(10-01 10:00) 取 001×200 002×150→MIX-001；
# OP-0002(10-02 09:00) 取 MIX-001×100→ALQ-001）。
set -u
BASE=${BASE:-http://localhost:3300}
PASS=0; FAIL=0
j() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$@" 2>/dev/null; }
chk() { # desc expected actual
  if [ "$2" == "$3" ]; then echo "✓ $1"; PASS=$((PASS+1)); else echo "✗ $1 (expected [$2] got [$3])"; FAIL=$((FAIL+1)); fi
}
code() { curl -s -o /tmp/d_body -w '%{http_code}' -H 'Content-Type: application/json' "$@"; }
post() { curl -s -H 'Content-Type: application/json' "$@"; }

echo "==== 1. 基础登记与幂等 / 冲突 ===="
c=$(code -X POST $BASE/api/disposals -d '{"disposal_id":"DSP-T1","bottle":"W2026-003","disp_time":"2026-10-03T09:00","volume":100,"reason":"剩余销毁"}')
chk "首次处置 → 201" 201 "$c"
chk "处置后余量 400" 400 "$(j 'd["disposal"]["remaining_after"]' < /tmp/d_body)"
c=$(code -X POST $BASE/api/disposals -d '{"disposal_id":"DSP-T1","bottle":"W2026-003","disp_time":"2026-10-03T09:00","volume":100,"reason":"剩余销毁"}')
chk "同号同内容重试 → 200 幂等" 200 "$c"
chk "幂等不重复扣量（仍 400）" 400 "$(j 'd["disposal"]["remaining_after"]' < /tmp/d_body)"
c=$(code -X POST $BASE/api/disposals -d '{"disposal_id":"DSP-T1","bottle":"W2026-003","disp_time":"2026-10-03T09:00","volume":120,"reason":"剩余销毁"}')
chk "同号异内容 → 409 DISPOSAL_CONFLICT" 409 "$c"
chk "错误码" DISPOSAL_CONFLICT "$(j 'd["error"]["code"]' < /tmp/d_body)"

echo "==== 2. 输入校验 ===="
c=$(code -X POST $BASE/api/disposals -d '{"disposal_id":"DSP-T2","bottle":"NOPE","disp_time":"2026-10-03T09:00","volume":10,"reason":"x"}')
chk "瓶不存在 → 400 BOTTLE_NOT_FOUND" 400 "$c"; chk "码" BOTTLE_NOT_FOUND "$(j 'd["error"]["code"]' < /tmp/d_body)"
c=$(code -X POST $BASE/api/disposals -d '{"disposal_id":"DSP-T2","bottle":"W2026-003","disp_time":"2026-10-01T08:00","volume":10,"reason":"x"}')
chk "处置时间早于瓶形成（采样 10-01T08:30）→ 400" 400 "$c"; chk "码" TIME_BEFORE_BOTTLE_FORMATION "$(j 'd["error"]["code"]' < /tmp/d_body)"
c=$(code -X POST $BASE/api/disposals -d '{"disposal_id":"DSP-T2","bottle":"W2026-003","disp_time":"2026-10-03T09:00","volume":0,"reason":"x"}')
chk "体积非正整数 → 400 BAD_VOLUME" 400 "$c"; chk "码" BAD_VOLUME "$(j 'd["error"]["code"]' < /tmp/d_body)"
c=$(code -X POST $BASE/api/disposals -d '{"disposal_id":"DSP-T2","bottle":"W2026-003","disp_time":"2026-10-03T09:00","volume":10,"reason":"  "}')
chk "原因空白 → 400 BAD_ID" 400 "$c"
# 衍生瓶：MIX-001 形成时间 10-01T10:00
c=$(code -X POST $BASE/api/disposals -d '{"disposal_id":"DSP-T2","bottle":"MIX-001","disp_time":"2026-10-01T09:59","volume":10,"reason":"x"}')
chk "衍生瓶处置早于形成时间 → 400" 400 "$c"; chk "码" TIME_BEFORE_BOTTLE_FORMATION "$(j 'd["error"]["code"]' < /tmp/d_body)"

echo "==== 3. 时间重放：处置使后续取用超量 → 整笔拒绝 ===="
# MIX-001：OP-0001 于 10-01T10:00 形成 350；OP-0002 于 10-02T09:00 取 100 → 余量 250。
# 若在 10-01T11:00 处置 300，则 OP-0002 取用 100 时只剩 50 → 超量，必须拒绝。
c=$(code -X POST $BASE/api/disposals -d '{"disposal_id":"DSP-T3","bottle":"MIX-001","disp_time":"2026-10-01T11:00","volume":300,"reason":"x"}')
chk "使后续 OP-0002 超量 → 409 OVERDRAW" 409 "$c"; chk "码" OVERDRAW "$(j 'd["error"]["code"]' < /tmp/d_body)"
chk "冲突操作=OP-0002" OP-0002 "$(j 'd["error"]["details"][0]["op_id"]' < /tmp/d_body)"
chk "冲突瓶=MIX-001" MIX-001 "$(j 'd["error"]["details"][0]["bottle"]' < /tmp/d_body)"
chk "MIX-001 余量不变仍 250" 250 "$(curl -s $BASE/api/bottles | j '[x for x in d if x["id"]=="MIX-001"][0]["remaining"]')"
# 同一时间戳按入库顺序：处置在 OP-0002 之后（新 seq）→ 处置时间 10-02T09:00 时先扣 OP-0002 再处置，250 可处置
c=$(code -X POST $BASE/api/disposals -d '{"disposal_id":"DSP-T3B","bottle":"MIX-001","disp_time":"2026-10-02T09:00","volume":250,"reason":"全部剩余销毁"}')
chk "同时间戳处置在取用之后 → 201" 201 "$c"
chk "处置后余量 0" 0 "$(j 'd["disposal"]["remaining_after"]' < /tmp/d_body)"
# 处置后再登记更早/同刻取用应超量
c=$(code -X POST $BASE/api/operations -d '{"op_id":"OP-T3C","target_bottle":"MIX-T3C","op_time":"2026-10-02T09:00","sources":[{"bottle":"MIX-001","volume":1}]}')
chk "处置后同刻新取用（seq 在后）→ 409" 409 "$c"

echo "==== 4. 有效预约锁定量不得被处置占用 ===="
# W2026-002 当前余量 650。锁定 600。
post -X POST $BASE/api/reservations -d '{"reservation_id":"RSV-T4","expires_at":"2026-12-31T00:00","sources":[{"bottle":"W2026-002","volume":600}]}' > /dev/null
c=$(code -X POST $BASE/api/disposals -d '{"disposal_id":"DSP-T4","bottle":"W2026-002","disp_time":"2026-10-03T10:00","volume":51,"reason":"x"}')
chk "处置超未锁定余量（650-600=50）→ 409" 409 "$c"; chk "码" DISPOSAL_LOCKED_INSUFFICIENT "$(j 'd["error"]["code"]' < /tmp/d_body)"
c=$(code -X POST $BASE/api/disposals -d '{"disposal_id":"DSP-T4","bottle":"W2026-002","disp_time":"2026-10-03T10:00","volume":50,"reason":"x"}')
chk "处置恰好未锁定余量 50 → 201" 201 "$c"
chk "处置后余量 600（锁定仍满足）" 600 "$(j 'd["disposal"]["remaining_after"]' < /tmp/d_body)"
# 预约仍可兑现
c=$(code -X POST $BASE/api/operations -d '{"op_id":"OP-T4F","target_bottle":"MIX-T4F","op_time":"2026-10-04T09:00","reservation_id":"RSV-T4","sources":[{"bottle":"W2026-002","volume":600}]}')
chk "锁定量仍可兑现 → 201" 201 "$c"

echo "==== 5. 已失效 / 受隔离瓶仍可处置 ===="
post -X POST $BASE/api/bottles -d '{"bottle_id":"W2026-T5","sample_time":"2026-09-01T08:00","initial_volume":100,"expires_at":"2026-09-02T08:00"}' > /dev/null
c=$(code -X POST $BASE/api/disposals -d '{"disposal_id":"DSP-T5","bottle":"W2026-T5","disp_time":"2026-10-03T10:00","volume":100,"reason":"失效销毁"}')
chk "已失效瓶可处置 → 201" 201 "$c"
post -X PUT $BASE/api/bottles/W2026-001/quarantine -d '{"reason":"超标待复检"}' > /dev/null
c=$(code -X POST $BASE/api/disposals -d '{"disposal_id":"DSP-T5Q","bottle":"ALQ-001","disp_time":"2026-10-03T10:00","volume":100,"reason":"受影响销毁"}')
chk "受隔离影响瓶（ALQ-001）可处置 → 201" 201 "$c"
post -X DELETE $BASE/api/bottles/W2026-001/quarantine > /dev/null

echo "==== 6. 批次提交计入处置扣量 + 凭据失效 ===="
# W2026-001：余量 800。预演批次取 800 应可行；随后处置 100（未锁定）后旧凭据提交须失败。
PV=$(post -X POST $BASE/api/batches/preview -d '{"batch_id":"BATCH-T6","items":[{"op_id":"OP-T6","target_bottle":"MIX-T6","op_time":"2026-10-05T09:00","sources":[{"bottle":"W2026-001","volume":800}]}]}')
chk "批次预演可行" True "$(echo "$PV" | j 'd["ok"]')"
TOK=$(echo "$PV" | j 'd["commit_token"]')
c=$(code -X POST $BASE/api/disposals -d '{"disposal_id":"DSP-T6","bottle":"W2026-001","disp_time":"2026-10-05T08:00","volume":100,"reason":"预演后处置"}')
chk "处置登记 → 201" 201 "$c"
c=$(code -X POST $BASE/api/batches/commit -d "{\"batch_id\":\"BATCH-T6\",\"items\":[{\"op_id\":\"OP-T6\",\"target_bottle\":\"MIX-T6\",\"op_time\":\"2026-10-05T09:00\",\"sources\":[{\"bottle\":\"W2026-001\",\"volume\":800}]}],\"commit_token\":\"$TOK\"}")
chk "处置后旧批次凭据 → 409 STALE_TOKEN" 409 "$c"; chk "码" STALE_TOKEN "$(j 'd["error"]["code"]' < /tmp/d_body)"
# 重新预演：取 800 已不可行（处置在 08:00，取在 09:00，余 700）
PV=$(post -X POST $BASE/api/batches/preview -d '{"batch_id":"BATCH-T6","items":[{"op_id":"OP-T6","target_bottle":"MIX-T6","op_time":"2026-10-05T09:00","sources":[{"bottle":"W2026-001","volume":800}]}]}')
chk "重新预演不可行（处置计入）" False "$(echo "$PV" | j 'd["ok"]')"
# 处置时间晚于批次取用（10:00）则批次可行；同批预演 700 也可行
PV=$(post -X POST $BASE/api/batches/preview -d '{"batch_id":"BATCH-T6","items":[{"op_id":"OP-T6","target_bottle":"MIX-T6","op_time":"2026-10-05T09:00","sources":[{"bottle":"W2026-001","volume":700}]}]}')
TOK=$(echo "$PV" | j 'd["commit_token"]')
c=$(code -X POST $BASE/api/batches/commit -d "{\"batch_id\":\"BATCH-T6\",\"items\":[{\"op_id\":\"OP-T6\",\"target_bottle\":\"MIX-T6\",\"op_time\":\"2026-10-05T09:00\",\"sources\":[{\"bottle\":\"W2026-001\",\"volume\":700}]}],\"commit_token\":\"$TOK\"}")
chk "取 700（处置 100 后剩 700）批次提交 → 201" 201 "$c"

echo "==== 7. 历史更正：使处置无法满足 → 整体回滚 ===="
# OP-0001 原取 W2026-001×200、W2026-002×150（10-01T10:00 → MIX-001）。
# DSP-T3B 在 10-02T09:00 把 MIX-001 余量 250 全部处置。若把 OP-0001 改为 002×350（MIX-001 仍 350），
# 但改为 001×200+002×140 → MIX-001 形成 340，OP-0002 取 100 后 240，DSP-T3B 需 250 → 超量 → 更正拒绝。
c=$(code -X POST $BASE/api/operations/OP-0001/correct -d '{"sources":[{"bottle":"W2026-001","volume":200},{"bottle":"W2026-002","volume":140}]}')
chk "更正使处置 DSP-T3B 超量 → 409" 409 "$c"; chk "码" CORRECTION_REJECTED "$(j 'd["error"]["code"]' < /tmp/d_body)"
chk "冲突指向处置 DSP-T3B" DSP-T3B "$(j '[x for x in d["error"]["details"] if x.get("disposal_id")=="DSP-T3B"][0]["disposal_id"]' < /tmp/d_body)"
chk "回滚后 W2026-002 取用量不变（MIX-001 余量 0：350-100-250）" 0 "$(curl -s $BASE/api/bottles | j '[x for x in d if x["id"]=="MIX-001"][0]["remaining"]')"

echo "==== 8. 历史更正：使有效预约无法满足 → 整体回滚 ===="
post -X POST $BASE/api/bottles -d '{"bottle_id":"W2026-T8C","sample_time":"2026-09-20T08:00","initial_volume":200}' > /dev/null
post -X POST $BASE/api/operations -d '{"op_id":"OP-T8C","target_bottle":"MIX-T8C","op_time":"2026-09-22T08:00","sources":[{"bottle":"W2026-T8C","volume":100}]}' > /dev/null
# 预约锁定 MIX-T8C 100（余量 100，可锁）
post -X POST $BASE/api/reservations -d '{"reservation_id":"RSV-T8C","expires_at":"2026-12-31T00:00","sources":[{"bottle":"MIX-T8C","volume":100}]}' > /dev/null
# 更正 OP-T8C：改为从 W2026-T8C 取 50（MIX-T8C 形成 50 < 有效预约锁定 100）→ RESERVATION_EXCEEDED
c=$(code -X POST $BASE/api/operations/OP-T8C/corrections/preview -d '{"sources":[{"bottle":"W2026-T8C","volume":50}]}')
chk "更正比形成量小于预约锁定 → 预演失败" False "$(j 'd["ok"]' < /tmp/d_body)"
chk "预演给出 RESERVATION_EXCEEDED" RESERVATION_EXCEEDED "$(j '[e["code"] for e in d["errors"] if e["code"]=="RESERVATION_EXCEEDED"][0]' < /tmp/d_body)"
c=$(code -X POST $BASE/api/operations/OP-T8C/correct -d '{"sources":[{"bottle":"W2026-T8C","volume":50}]}')
chk "立即更正同样拒绝 → 409 RESERVATION_EXCEEDED" 409 "$c"; chk "码" RESERVATION_EXCEEDED "$(j 'd["error"]["code"]' < /tmp/d_body)"
chk "回滚后 MIX-T8C 形成量仍 100（余量 100，锁定 100 满足）" 100 "$(curl -s $BASE/api/bottles | j '[x for x in d if x["id"]=="MIX-T8C"][0]["remaining"]')"

echo "==== 9. 更正预演凭据在处置后失效 ===="
PV=$(post -X POST $BASE/api/operations/OP-0002/corrections/preview -d '{"sources":[{"bottle":"MIX-001","volume":100}]}')
TOK=$(echo "$PV" | j 'd["confirm_token"]')
chk "OP-0002 原样更正预演通过" True "$(echo "$PV" | j 'd["ok"]')"
post -X POST $BASE/api/disposals -d '{"disposal_id":"DSP-T9","bottle":"W2026-003","disp_time":"2026-10-06T08:00","volume":10,"reason":"使凭据失效"}' > /dev/null
c=$(code -X POST $BASE/api/operations/OP-0002/corrections/confirm -d "{\"sources\":[{\"bottle\":\"MIX-001\",\"volume\":100}],\"confirm_token\":\"$TOK\"}")
chk "处置后旧更正凭据 → 409 STALE_TOKEN" 409 "$c"; chk "码" STALE_TOKEN "$(j 'd["error"]["code"]' < /tmp/d_body)"

echo "==== 10. 查询流水 / 单条 / 按瓶过滤 / 瓶详情 ===="
c=$(code $BASE/api/disposals)
chk "流水列表 200" 200 "$c"
chk "含 DSP-T1" DSP-T1 "$(j '[x["disposal_id"] for x in d["disposals"] if x["disposal_id"]=="DSP-T1"][0]' < /tmp/d_body)"
chk "DSP-T1 处置后余量 400" 400 "$(j '[x for x in d["disposals"] if x["disposal_id"]=="DSP-T1"][0]["remaining_after"]' < /tmp/d_body)"
c=$(code "$BASE/api/disposals?bottle=W2026-003")
n=$(j 'len(d["disposals"])' < /tmp/d_body)
allf=$(j 'all(x["bottle"]=="W2026-003" for x in d["disposals"])' < /tmp/d_body)
chk "按瓶过滤仅 W2026-003" True "$allf"
c=$(code $BASE/api/disposals/DSP-T3B)
chk "单条 200" 200 "$c"
chk "单条处置后余量 0" 0 "$(j 'd["remaining_after"]' < /tmp/d_body)"
c=$(code $BASE/api/disposals/NOPE)
chk "单条不存在 404" 404 "$c"
c=$(code $BASE/api/bottles/MIX-001)
chk "瓶详情含 disposals" DSP-T3B "$(j '[x["disposal_id"] for x in d["disposals"] if x["disposal_id"]=="DSP-T3B"][0]' < /tmp/d_body)"
chk "处置不改谱系：MIX-001 仍由 OP-0001 形成" OP-0001 "$(j 'd["created_op"]' < /tmp/d_body)"
chk "处置不生成新瓶（总数无 DSP 瓶）" 0 "$(curl -s $BASE/api/bottles | j 'len([x for x in d if x["id"].startswith("DSP")])')"

echo "==== 11. 并发：同号只扣一次 ===="
for i in 1 2 3 4 5; do
  curl -s -o /tmp/cc$i -H 'Content-Type: application/json' -X POST $BASE/api/disposals -d "{\"disposal_id\":\"DSP-CONC\",\"bottle\":\"W2026-003\",\"disp_time\":\"2026-10-06T09:0$i\",\"volume\":10,\"reason\":\"并发$i\"}" &
done
wait
codes=""; for i in 1 2 3 4 5; do codes="$codes $(j 'd.get("idempotent")' /dev/null 2>/dev/null < /tmp/cc$i)"; done
# 第一次提交内容固定（disp_time 不同导致只有 1 笔成功，其余冲突），检查余量只扣 10
rem=$(curl -s $BASE/api/bottles | j '[x for x in d if x["id"]=="W2026-003"][0]["remaining"]')
# W2026-003: 500 - DSP-T1 100 - DSP-T9 10 = 390；并发成功一笔再 -10 = 380（仅一笔成功，其余 409）
chk "并发后余量 380（仅一笔扣量）" 380 "$rem"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
