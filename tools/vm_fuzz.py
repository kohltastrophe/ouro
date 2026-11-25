#!/usr/bin/env python3
"""Seeded structured Compiler + VM differential fuzzer against parser-oracle. MIT."""
import argparse
import hashlib
import json
import pathlib
import random
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_ORACLE = pathlib.Path(tempfile.gettempdir()) / 'ouro-build' / 'parser-oracle'
REVISION = json.loads((ROOT / 'UPSTREAM.json').read_text())['commit']


def gen_arithmetic(rng: random.Random, idx: int) -> str:
    a = rng.randint(-50, 50)
    b = rng.choice([i for i in range(-15, 16) if i != 0])
    c = rng.randint(1, 7)
    d = rng.randint(2, 5)
    return f"""
local x{idx}, y{idx}, z{idx} = {a}, {b}, {c}
local r1 = (x{idx} + y{idx}) * z{idx} - (-x{idx})
local r2 = x{idx} // y{idx} + (x{idx} % y{idx})
local r3 = (z{idx} ^ {d}) + (x{idx} / {d})
x{idx} += 3; x{idx} -= 1; x{idx} *= 2; x{idx} //= {d}
local cmp = (r1 > r2) and (r2 ~= r3) or (x{idx} <= z{idx})
print("arith", r1, r2, math.floor(r3 * 100), x{idx}, cmp)
return r1 + r2 + x{idx}
"""


def gen_bitwise(rng: random.Random, idx: int) -> str:
    u = rng.randint(0, 0xFFFF)
    v = rng.randint(1, 0xFFFF)
    sh = rng.randint(0, 15)
    f = rng.randint(0, 12)
    w = rng.randint(1, 8)
    return f"""
local a{idx}, b{idx} = {u}, {v}
local p = bit32.band(a{idx}, b{idx}) + bit32.bor(a{idx}, b{idx})
local q = bit32.bxor(a{idx}, bit32.bnot(b{idx}))
local r = bit32.lshift(a{idx}, {sh}) + bit32.rshift(b{idx}, {sh}) + bit32.arshift(-a{idx} - 1, {sh % 8})
local s = bit32.lrotate(a{idx}, {sh}) + bit32.rrotate(b{idx}, {sh})
local t = bit32.extract(a{idx}, {f}, {w}) + bit32.replace(b{idx}, 5, {f}, {w})
local m = bit32.countlz(a{idx} + 1) + bit32.countrz(b{idx}) + bit32.byteswap(a{idx})
local bt = bit32.btest(a{idx}, b{idx})
print("bit", p, q, r, s, t, m, bt)
return bit32.bxor(p, q, r, s, t, m)
"""


def gen_strings(rng: random.Random, idx: int) -> str:
    words = ['alpha', 'Beta', 'gamma9', 'Luau_0', 'xyz']
    s1 = rng.choice(words)
    s2 = rng.choice(words)
    rep_n = rng.randint(1, 4)
    sub_i = rng.randint(1, 3)
    return f"""
local s1, s2 = "{s1}", "{s2}"
local joined = s1 .. "-" .. s2 .. `[{rep_n}:{s1}]`
local sub = string.sub(joined, {sub_i}, {sub_i + 5})
local u = string.upper(sub) .. ":" .. string.lower(s2)
local rp = string.rep(s1, {rep_n})
local rv = string.reverse(s1)
local f1, f2 = string.find(joined, "%d+")
local m = string.match(joined, "(%a+)")
local gs, gc = string.gsub(joined, "%l", "X")
local fmt = string.format("%s|%d|%04x", m or "none", #rp, string.byte(s1, 1))
local ch = string.char(65 + ({idx} % 26), 97 + ({idx} % 26))
print("str", joined, sub, u, rv, f1, f2, gs, gc, fmt, ch)
return #joined + gc
"""


def gen_math(rng: random.Random, idx: int) -> str:
    n1 = rng.randint(-40, 40)
    n2 = rng.randint(1, 40)
    t = rng.choice([0.0, 0.25, 0.5, 0.75, 1.0])
    return f"""
local a, b = {n1}, {n2}
local v1 = math.abs(a) + math.floor(a / 3) + math.ceil(b / 3) + math.round(a / 2)
local v2 = math.min(a, b, 10) + math.max(a, b, -5) + math.clamp(a, -10, 10) + math.sign(a)
local v3 = math.floor(math.sqrt(b) * 1000) + math.floor(math.fmod(a, 7)) + math.pow(2, {idx % 6})
local v4 = math.floor((math.sin(1.25) + math.cos(0.75)) * 1000) + math.lerp(a, b, {t})
print("math", v1, v2, v3, v4)
return v1 + v2 + v3
"""


def gen_table_builtins(rng: random.Random, idx: int) -> str:
    n = rng.randint(3, 6)
    vals = [rng.randint(1, 50) for _ in range(n)]
    arr_lit = ', '.join(str(v) for v in vals)
    return f"""
local t = table.create({n}, {idx % 7})
local src = {{ {arr_lit} }}
table.move(src, 1, #src, 1, t)
table.insert(t, 2, 99)
local rem = table.remove(t, 3)
local idxFound = table.find(t, 99)
local cl = table.clone(t)
table.sort(cl)
local cat = table.concat(cl, ",")
local pk = table.pack(table.unpack(cl, 1, 3))
table.freeze(cl)
local frz = table.isfrozen(cl)
table.clear(t)
print("tbl", rem, idxFound, cat, pk.n, pk[1], frz, #t)
return (rem or 0) + #cat + pk.n
"""


def gen_buffers(rng: random.Random, idx: int) -> str:
    i8 = rng.randint(-100, 100)
    u16 = rng.randint(100, 60000)
    i32 = rng.randint(-100000, 100000)
    f32 = rng.choice([1.5, -2.25, 3.75])
    f64 = rng.choice([12.125, -45.5, 0.25])
    return f"""
local b = buffer.create(24)
buffer.writei8(b, 0, {i8})
buffer.writeu8(b, 1, {(idx * 17) % 255})
buffer.writei16(b, 2, {-u16 // 2})
buffer.writeu16(b, 4, {u16})
buffer.writei32(b, 6, {i32})
buffer.writeu32(b, 10, {abs(i32) + 1})
buffer.writef32(b, 14, {f32})
buffer.writef64(b, 16, {f64})
local b2 = buffer.create(8)
buffer.copy(b2, 0, b, 0, 8)
buffer.fill(b2, 4, 65 + ({idx} % 20), 4)
local s = buffer.tostring(b2)
local b3 = buffer.fromstring(s)
local sum = buffer.readi8(b, 0) + buffer.readu8(b, 1) + buffer.readi16(b, 2) + buffer.readu16(b, 4)
local sum2 = buffer.readi32(b, 6) + buffer.readu32(b, 10) + buffer.readf32(b, 14) + buffer.readf64(b, 16)
print("buf", buffer.len(b), buffer.len(b3), sum, sum2, string.byte(s, 5))
return sum + sum2
"""


def gen_closures_upvalues(rng: random.Random, idx: int) -> str:
    base = rng.randint(1, 20)
    steps = rng.randint(2, 5)
    return f"""
local function makeCounter(init: number)
    local acc = init
    local fns = {{}}
    for i = 1, {steps} do
        local delta = i * 2
        do
            local bias = i + {base}
            fns[i] = function(mul: number)
                acc += delta * mul
                delta += 1
                return function(extra: number)
                    return acc + bias + extra + i
                end
            end
        end
    end
    return fns, function() return acc end
end
local list, getAcc = makeCounter({base})
local total = 0
for i = 1, #list do
    local inner = list[i](i)
    total += inner(i)
end
print("clo", total, getAcc())
return total + getAcc()
"""


def gen_loops(rng: random.Random, idx: int) -> str:
    n = rng.randint(4, 9)
    skip = rng.randint(2, n - 1)
    return f"""
local acc = 0
for i = 1, {n}, 1 do
    if i == {skip} then continue end
    if i == {n} then break end
    acc += i * 3
end
for i = {n}, 1, -2 do
    acc += i
end
local w = 0
while w < {n} do
    w += 1
    if w % 2 == 0 then continue end
    acc += w
end
local r = 0
repeat
    local step = r + 1
    r = step
    if r == 2 then continue end
    acc += step
until r >= {n}
local arr = {{ 3, 5, 7, 11 }}
for i, v in ipairs(arr) do
    acc += i * v
end
for i, v in arr do
    acc += i + v
end
local dict = {{ a = 10, b = 20, c = 30 }}
local dsum = 0
for _, v in pairs(dict) do
    dsum += v
end
print("loop", acc, dsum)
return acc + dsum
"""


def gen_metamethods(rng: random.Random, idx: int) -> str:
    v1 = rng.randint(1, 20)
    v2 = rng.randint(1, 20)
    return f"""
local mt
mt = {{
    __add = function(a, b) return setmetatable({{ x = a.x + b.x }}, mt) end,
    __sub = function(a, b) return setmetatable({{ x = a.x - b.x }}, mt) end,
    __mul = function(a, b) return setmetatable({{ x = a.x * b.x }}, mt) end,
    __len = function(a) return a.x + 100 end,
    __tostring = function(a) return "Box(" .. tostring(a.x) .. ")" end,
    __concat = function(a, b) return tostring(a) .. ":" .. tostring(b) end,
    __eq = function(a, b) return a.x == b.x end,
    __lt = function(a, b) return a.x < b.x end,
    __call = function(a, k) return a.x * k end,
    __index = function(_self, k) return if k == "double" then _self.x * 2 else nil end,
    __newindex = function(self, k, v) rawset(self, k, v * 2) end,
    __iter = function(self)
        local i = 0
        return function()
            i += 1
            if i <= 3 then return i, self.x + i end
            return nil
        end
    end,
}}
local a = setmetatable({{ x = {v1} }}, mt)
local b = setmetatable({{ x = {v2} }}, mt)
local c = (a + b) * setmetatable({{ x = 2 }}, mt) - a
a.extra = 7
local itSum = 0
for k, val in a do
    itSum += k * val
end
print("mm", tostring(c), #c, a .. b, a == b, a < b, c(3), a.double, a.extra, itSum)
return c.x + #c + c(3) + itSum
"""


def gen_varargs_pcall(rng: random.Random, idx: int) -> str:
    v1 = rng.randint(1, 25)
    v2 = rng.randint(1, 25)
    should_err = (idx % 2 == 0)
    return f"""
local function collect(head, ...)
    local cnt = select("#", ...)
    local second = select(2, ...)
    local packed = {{ head, ... }}
    return cnt, second, #packed, table.unpack(packed)
end
local c1, s2, plen, u1, u2, u3 = collect({v1}, {v2}, {v1 + v2}, "z")
local function risky(flag)
    if flag then
        error("boom-{idx}")
    end
    return {v1} * 2, {v2} * 3
end
local ok1, r1, r2 = pcall(risky, false)
local ok2, err2 = pcall(risky, {str(should_err).lower()})
local ok3, res3 = xpcall(function()
    local innerOk, innerErr = pcall(risky, true)
    if not innerOk then error("wrapped:" .. tostring(innerErr)) end
    return 0
end, function(e)
    return "handled[" .. tostring(e) .. "]"
end)
print("va", c1, s2, plen, u1, u2, u3, ok1, r1, r2, ok2, err2, ok3, res3)
return c1 + plen + (r1 or 0) + (r2 or 0)
"""


GENERATORS = [
    ('arith', gen_arithmetic),
    ('bitwise', gen_bitwise),
    ('strings', gen_strings),
    ('math', gen_math),
    ('table', gen_table_builtins),
    ('buffer', gen_buffers),
    ('closure', gen_closures_upvalues),
    ('loop', gen_loops),
    ('metamethod', gen_metamethods),
    ('varargs_pcall', gen_varargs_pcall),
]


def build_cases(count: int, seed: int) -> list[dict]:
    rng = random.Random(seed)
    cases = []
    for i in range(count):
        kind, gen_fn = GENERATORS[i % len(GENERATORS)]
        # Add subtle random variation across repeats
        src = gen_fn(rng, i).strip() + '\n'
        cases.append({
            'name': f'vm_fuzz_{seed}_{i}_{kind}',
            'source': src,
            'profile': 'upstream',
            'flags': {},
            'origin': f'vm_fuzz.py seed={seed} index={i} kind={kind}',
        })
    return cases


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--oracle', type=pathlib.Path, default=DEFAULT_ORACLE, help='Path to parser-oracle binary')
    ap.add_argument('--luau', default='luau', help='Luau CLI executable')
    ap.add_argument('--count', type=int, default=200, help='Number of generated programs')
    ap.add_argument('--seed', type=int, default=7482026, help='PRNG seed')
    ap.add_argument('--report', type=pathlib.Path, help='Optional JSON report output path')
    args = ap.parse_args()
    assert args.count > 0, '--count must be positive'

    cases = build_cases(args.count, args.seed)
    with tempfile.TemporaryDirectory(prefix='ouro-vm-fuzz-') as temp:
        tmp = pathlib.Path(temp)
        fixture_path = tmp / 'fixtures.json'
        fixture_path.write_text(json.dumps(cases, indent=2) + '\n')

        compile_report_path = tmp / 'compile.json'
        vm_report_path = tmp / 'vm.json'

        compile_cmd = [
            sys.executable,
            str(ROOT / 'tests/differential.py'),
            '--fixtures', str(fixture_path),
            '--compile',
            '--oracle', str(args.oracle),
            '--luau', args.luau,
            '--report', str(compile_report_path),
        ]
        vm_cmd = [
            sys.executable,
            str(ROOT / 'tests/differential.py'),
            '--fixtures', str(fixture_path),
            '--vm',
            '--oracle', str(args.oracle),
            '--luau', args.luau,
            '--report', str(vm_report_path),
        ]

        compile_res = subprocess.run(compile_cmd, cwd=ROOT, timeout=600)
        vm_res = subprocess.run(vm_cmd, cwd=ROOT, timeout=600)

        compile_rep = json.loads(compile_report_path.read_text()) if compile_report_path.is_file() else {}
        vm_rep = json.loads(vm_report_path.read_text()) if vm_report_path.is_file() else {}

        all_failures = []
        for f in compile_rep.get('failures', []):
            all_failures.append({'stage': 'compile', **f})
        for f in vm_rep.get('failures', []):
            all_failures.append({'stage': 'vm', **f})

        failed_names = {f['name'] for f in all_failures}
        reports_ready = compile_report_path.is_file() and vm_report_path.is_file()
        passed_both = (args.count - len(failed_names)) if reports_ready else 0

        report = {
            'fixtureSha256': hashlib.sha256(fixture_path.read_bytes()).hexdigest(),
            'oracleBinarySha256': hashlib.sha256(args.oracle.read_bytes()).hexdigest(),
            'revision': REVISION,
            'mode': 'vm-fuzz',
            'seed': args.seed,
            'fixtures': args.count,
            'passed': passed_both,
            'failed': len(failed_names) if reports_ready else args.count,
            'compilePassed': compile_rep.get('passed', 0),
            'compileFailed': compile_rep.get('failed', 0),
            'vmPassed': vm_rep.get('passed', 0),
            'vmFailed': vm_rep.get('failed', 0),
            'failures': all_failures,
        }
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(report, indent=2) + '\n')

    if compile_res.returncode or vm_res.returncode:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
