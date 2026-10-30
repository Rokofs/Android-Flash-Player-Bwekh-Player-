"""
Deobfuscator for AS2 (AVM1) code protected by a control-flow-flattening obfuscator
(the kind seen in 945a's Moyea FLV player and rga):

  - each block is a `while(true)` dispatcher on a state variable "\\x01" whose start value
    comes from a helper function "\\x04\\x05" (set "\\x03", return it)
  - opaque predicates through junk variables ("\\x0f" = 1, `!eval("\\x0f")`), junk pushes
  - code split across tags: jumps leave the block into bytes hidden in other tags
    ("trampolines"), constant pools switched on the way, so decompilers show garbage

How: a partial evaluator walks the code from the block start, keeping values that are known
at compile time (constants, the obfuscator's control-character variables) and executing
everything that depends only on them. Instructions that touch real runtime values are
emitted; branches on runtime values fork. The result is a linear block (no dispatcher, no
constant pool, pool strings inlined) written back into a copy of the SWF.

usage: python3 deob.py in.swf out.swf [-v]
"""
import sys, struct, math, zlib
from avm1 import read, push_values, parse_pool, branch_target, func_info, NAMES

class Bail(Exception):
    pass

UNDEF = ('undef', None)

def is_obf_name(s):
    return isinstance(s, str) and s != '' and all(ord(ch) < 0x20 for ch in s)

# ------------------------------------------------------------------ AS2 value semantics (for known values)
def to_num(v):
    t, x = v
    if t == 'num': return x
    if t == 'bool': return 1.0 if x else 0.0
    if t == 'str':
        try: return float(x) if x.strip() else 0.0
        except ValueError:
            try: return float(int(x, 16)) if x.lower().startswith('0x') else math.nan
            except ValueError: return math.nan
    if t == 'null': return 0.0
    return math.nan  # undefined (swf7+)

def to_str(v):
    t, x = v
    if t == 'str': return x
    if t == 'bool': return 'true' if x else 'false'
    if t == 'null': return 'null'
    if t == 'undef': return 'undefined'
    if t == 'num':
        if math.isnan(x): return 'NaN'
        if x == int(x) and abs(x) < 1e15: return str(int(x))
        return repr(x)
    raise Bail('to_str ' + t)

def to_bool(v):
    t, x = v
    if t == 'bool': return x
    if t == 'num': return not (x == 0 or math.isnan(x))
    if t == 'str': return x != ''  # swf7+
    return False

def to_i32(v):
    n = to_num(v)
    if math.isnan(n) or math.isinf(n): return 0
    n = int(n) & 0xffffffff
    return n - 0x100000000 if n & 0x80000000 else n

def num(x): return ('num', float(x))

def eq2(a, b):
    ta, tb = a[0], b[0]
    if ta == tb:
        if ta == 'num': return a[1] == b[1]
        return a[1] == b[1]
    if {ta, tb} <= {'null', 'undef'}: return True
    if ta in ('null', 'undef') or tb in ('null', 'undef'): return False
    return to_num(a) == to_num(b)

def pure_op(code, args):
    """result of a pure op on known args (top of stack last), or raises Bail"""
    if code in (0x0a, 0x0b, 0x0c, 0x0d, 0x3f):
        a, b = to_num(args[0]), to_num(args[1])
        if code == 0x0a: return num(a + b)
        if code == 0x0b: return num(a - b)
        if code == 0x0c: return num(a * b)
        if code == 0x0d: return num(a / b if b else (math.nan if a == 0 or math.isnan(a) else math.copysign(math.inf, a)))
        return num(math.fmod(a, b) if b else math.nan)
    if code == 0x47:  # Add2
        a, b = args
        if a[0] == 'str' or b[0] == 'str': return ('str', to_str(a) + to_str(b))
        return num(to_num(a) + to_num(b))
    if code == 0x0e: return ('bool', to_num(args[0]) == to_num(args[1]))
    if code == 0x0f: return ('bool', to_num(args[0]) < to_num(args[1]))
    if code == 0x48:
        a, b = args
        if a[0] == 'str' and b[0] == 'str': return ('bool', a[1] < b[1])
        x, y = to_num(a), to_num(b)
        if math.isnan(x) or math.isnan(y): return UNDEF
        return ('bool', x < y)
    if code == 0x67:
        a, b = args
        if a[0] == 'str' and b[0] == 'str': return ('bool', a[1] > b[1])
        x, y = to_num(a), to_num(b)
        if math.isnan(x) or math.isnan(y): return UNDEF
        return ('bool', x > y)
    if code == 0x49: return ('bool', eq2(args[0], args[1]))
    if code == 0x66: return ('bool', args[0][0] == args[1][0] and args[0][1] == args[1][1])
    if code == 0x10: return ('bool', to_bool(args[0]) and to_bool(args[1]))
    if code == 0x11: return ('bool', to_bool(args[0]) or to_bool(args[1]))
    if code == 0x12: return ('bool', not to_bool(args[0]))
    if code == 0x13: return ('bool', to_str(args[0]) == to_str(args[1]))
    if code == 0x29: return ('bool', to_str(args[0]) < to_str(args[1]))
    if code == 0x68: return ('bool', to_str(args[0]) > to_str(args[1]))
    if code == 0x21: return ('str', to_str(args[0]) + to_str(args[1]))
    if code in (0x14, 0x31): return num(len(to_str(args[0])))
    if code == 0x18: n = to_num(args[0]); return num(0 if math.isnan(n) else math.trunc(n))
    if code == 0x4a: return num(to_num(args[0]))
    if code == 0x4b: return ('str', to_str(args[0]))
    if code == 0x50: return num(to_num(args[0]) + 1)
    if code == 0x51: return num(to_num(args[0]) - 1)
    if code == 0x60: return num(to_i32(args[0]) & to_i32(args[1]))
    if code == 0x61: return num(to_i32(args[0]) | to_i32(args[1]))
    if code == 0x62: return num(to_i32(args[0]) ^ to_i32(args[1]))
    if code == 0x63: return num(to_i32((num(to_i32(args[0]) << (to_i32(args[1]) & 31)))))
    if code == 0x64: return num(to_i32(args[0]) >> (to_i32(args[1]) & 31))
    if code == 0x65: return num((to_i32(args[0]) & 0xffffffff) >> (to_i32(args[1]) & 31))
    if code == 0x32:
        s = to_str(args[0]); return num(ord(s[0]) if s else 0)
    if code == 0x33: return ('str', chr(to_i32(args[0]) & 0xff))
    if code == 0x44:
        t = args[0][0]
        return ('str', {'num': 'number', 'str': 'string', 'bool': 'boolean', 'null': 'null', 'undef': 'undefined'}[t])
    raise Bail('pure %02x' % code)

# ops that only compute from their inputs: code -> number of inputs (1 output)
PURE = {0x0a: 2, 0x0b: 2, 0x0c: 2, 0x0d: 2, 0x3f: 2, 0x47: 2, 0x0e: 2, 0x0f: 2, 0x48: 2, 0x67: 2, 0x49: 2, 0x66: 2,
        0x10: 2, 0x11: 2, 0x12: 1, 0x13: 2, 0x29: 2, 0x68: 2, 0x21: 2, 0x14: 1, 0x31: 1, 0x18: 1, 0x4a: 1, 0x4b: 1,
        0x50: 1, 0x51: 1, 0x60: 2, 0x61: 2, 0x62: 2, 0x63: 2, 0x64: 2, 0x65: 2, 0x32: 1, 0x33: 1, 0x44: 1}

# fixed stack effects of the other ops: code -> (pops, pushes)
FIXED = {0x04: (0, 0), 0x05: (0, 0), 0x06: (0, 0), 0x07: (0, 0), 0x08: (0, 0), 0x09: (0, 0), 0x15: (3, 1),
         0x35: (3, 1), 0x36: (1, 1), 0x37: (1, 1), 0x1c: (1, 1), 0x1d: (2, 0), 0x20: (1, 0), 0x22: (2, 1),
         0x23: (3, 0), 0x24: (3, 0), 0x25: (1, 0), 0x26: (1, 0), 0x28: (0, 0), 0x2a: (1, 0), 0x2b: (2, 1),
         0x30: (1, 1), 0x34: (0, 1), 0x3a: (2, 1), 0x3b: (1, 1), 0x3c: (2, 0), 0x41: (1, 0), 0x45: (1, 1),
         0x4e: (2, 1), 0x4f: (3, 0), 0x54: (2, 1), 0x69: (2, 0), 0x81: (0, 0), 0x83: (0, 0), 0x87: (0, 0),
         0x8b: (0, 0), 0x8c: (0, 0), 0x9a: (2, 0), 0x9e: (1, 0), 0x9f: (1, 0), 0x94: (1, 0), 0x17: (1, 0)}

class Entry:
    """a stack slot: a known value (val) or a runtime one (val None); mat = already in emitted code"""
    __slots__ = ('val', 'mat')
    def __init__(s, val, mat):
        s.val = val; s.mat = mat

MANY = 'many'  # stack below an Enumerate: unknown number of runtime values

class Unit:
    """deobfuscates one code region (a frame/init block or a function body)"""
    def __init__(s, buf, start, pool, verbose=False, depth=0, limit=400000):
        s.b = buf; s.start = start; s.pool = pool; s.v = verbose; s.depth = depth
        s.out = []           # emitted items: ('op', code, data) | ('label', id) | ('jump'/'if', labelid)
        s.labels = {}        # state key -> label id
        s.nlabel = 0
        s.work = []
        s.steps = 0; s.limit = limit
        s.funcs = {}         # obfuscator helper functions: name -> (body start, body end, pool)
        s.end = -1           # function body end (falling off it returns)
        s.joins = set()      # targets of runtime branches: the other path may arrive there by falling through

    # -- emitting
    def emit(s, code, data=b''):
        s.out.append(('op', code, data))

    def materialize(s, st):
        run = []
        for e in st:
            if e is MANY or e.mat: continue
            run.append(e)
        if not run: return
        # one Push with all of them
        s.out.append(('push', [e.val for e in run]))
        for e in run: e.mat = True

    # -- walking
    def key(s, pc, vars_, st):
        return (pc, tuple(sorted(vars_.items())), tuple('M' if e is MANY else (('m',) if e.mat and e.val is None else (e.mat, e.val)) for e in st))

    def run(s):
        # walk until the set of join points is complete (a join found late would duplicate code)
        for _ in range(6):
            before = set(s.joins)
            s.out = []; s.labels = {}; s.nlabel = 0; s.work = []; s.funcs = {}; s.steps = 0
            s.path(s.start, {}, [], s.pool, branch=True)
            while s.work:
                lab, pc, vars_, st, pool = s.work.pop()
                s.out.append(('label', lab))
                s.path(pc, vars_, st, pool, branch=False, lab_done=True)
            if s.joins == before: break
        return s.out

    def goto_or_label(s, pc, vars_, st, pool):
        """at a branch target: reuse the code made for the same state, else mark a label here"""
        k = s.key(pc, vars_, st)
        if k in s.labels:
            return s.labels[k], False
        lab = s.nlabel; s.nlabel += 1
        s.labels[k] = lab
        return lab, True

    def path(s, pc, vars_, st, pool, branch, lab_done=False):
        vars_ = dict(vars_)
        st = [e if e is MANY else Entry(e.val, e.mat) for e in st]
        b = s.b
        first = True
        while True:
            s.steps += 1
            if s.steps > s.limit: raise Bail('too long')
            if (branch or pc in s.joins) and not (first and lab_done):
                # a join point: same state seen before -> jump there
                lab, new = s.goto_or_label(pc, vars_, st, pool)
                if not new:
                    s.out.append(('jump', lab)); return
                s.out.append(('label', lab))
            first = False
            branch = False
            if pc < 0 or (pc >= len(b) and pc != s.end): raise Bail('pc out of file %d' % pc)
            op = read(b, pc) if pc != s.end else None
            if op is None:
                s.emit(0x00); return
            c = op.code
            nxt = op.end
            if c == 0x00 or c == 0x3e or pc == s.end:  # End / Return / end of a function body
                if c == 0x3e and pc != s.end:
                    s.need(st, 1); s.materialize(st); s.emit(0x3e)
                else:
                    s.emit(0x00)
                return
            if c == 0x88:  # ConstantPool: we inline the strings
                pool = parse_pool(op.data); pc = nxt; continue
            if c == 0x96:
                for t, x in push_values(op.data, pool):
                    if t == 'pool':
                        if pool is None or x >= len(pool): raise Bail('pool ref %d' % x)
                        st.append(Entry(('str', pool[x]), False))
                    elif t == 'reg':
                        s.materialize(st)
                        s.out.append(('push', [('reg', x)]))
                        st.append(Entry(None, True))
                    elif t == 'bad': raise Bail('bad push')
                    else:
                        st.append(Entry((t, x), False))
                pc = nxt; continue
            if c == 0x99:  # Jump
                pc = branch_target(op); branch = True; continue
            if c == 0x9d:  # If
                cond = s.pop(st)
                if cond.val is not None and not cond.mat:
                    if to_bool(cond.val): pc = branch_target(op); branch = True
                    else: pc = nxt
                    continue
                if cond.val is not None and cond.mat:
                    # a known value already emitted: drop it at runtime, decide here
                    s.emit(0x17)
                    if to_bool(cond.val): pc = branch_target(op); branch = True
                    else: pc = nxt
                    continue
                # runtime branch
                tgt = branch_target(op)
                s.joins.add(tgt)
                lab, new = s.goto_or_label(tgt, vars_, st, pool)
                s.out.append(('if', lab))
                if new:
                    s.work.append((lab, tgt, dict(vars_), [e if e is MANY else Entry(e.val, e.mat) for e in st], pool))
                pc = nxt; branch = True; continue
            if c in PURE:
                n = PURE[c]
                s.need(st, n)
                args = st[-n:]
                if all(e is not MANY and e.val is not None and not e.mat for e in args):
                    try:
                        r = pure_op(c, [e.val for e in args])
                        del st[-n:]
                        st.append(Entry(r, False)); pc = nxt; continue
                    except Bail:
                        pass
                s.real(st, c, op.data, n, 1); pc = nxt; continue
            if c == 0x17:  # Pop
                e = s.pop(st)
                if e is not MANY and e.mat: s.emit(0x17)
                elif e is MANY: s.emit(0x17); st.append(MANY)
                pc = nxt; continue
            if c == 0x4c:  # PushDuplicate
                s.need(st, 1)
                e = st[-1]
                if e is not MANY and not e.mat and e.val is not None: st.append(Entry(e.val, False))
                else:
                    s.materialize(st); s.emit(0x4c); st.append(Entry(None if e is MANY else e.val, True))
                pc = nxt; continue
            if c == 0x4d:  # StackSwap
                s.need(st, 2)
                a, bb = st[-2], st[-1]
                if a is not MANY and bb is not MANY and not a.mat and not bb.mat:
                    st[-2], st[-1] = bb, a
                else:
                    s.materialize(st); s.emit(0x4d)
                    st[-2], st[-1] = st[-1], st[-2]
                pc = nxt; continue
            if c == 0x1c:  # GetVariable
                s.need(st, 1)
                nm = st[-1]
                if nm is not MANY and not nm.mat and nm.val is not None and nm.val[0] == 'str' and is_obf_name(nm.val[1]):
                    st.pop()
                    st.append(Entry(vars_.get(nm.val[1], UNDEF), False)); pc = nxt; continue
                s.real(st, c, op.data, 1, 1); pc = nxt; continue
            if c in (0x1d, 0x3c):  # SetVariable / DefineLocal
                s.need(st, 2)
                nm, val = st[-2], st[-1]
                if nm is not MANY and not nm.mat and nm.val is not None and nm.val[0] == 'str' and is_obf_name(nm.val[1]) \
                        and val is not MANY and not val.mat and val.val is not None:
                    vars_[nm.val[1]] = val.val
                    del st[-2:]; pc = nxt; continue
                s.real(st, c, op.data, 2, 0); pc = nxt; continue
            if c in (0x9b, 0x8e):  # DefineFunction(2)
                name, params, blen, _, _ = func_info(op)
                body = nxt
                if is_obf_name(name):
                    s.funcs[name] = (body, body + blen, pool)
                    pc = body + blen; continue
                sub = Unit(b, body, pool, s.v, s.depth + 1, s.limit)
                sub_items = peephole(sub.run_fn(body + blen))
                s.materialize(st)
                s.out.append(('func', c, bytes(op.data[:-2]), sub_items))
                if name == '': st.append(Entry(None, True))
                pc = body + blen; continue
            if c == 0x3d:  # CallFunction
                s.need(st, 2)
                nm, cnt = st[-1], st[-2]
                if nm is not MANY and not nm.mat and nm.val and nm.val[0] == 'str' and nm.val[1] in s.funcs \
                        and cnt is not MANY and not cnt.mat and cnt.val is not None:
                    n = to_i32(cnt.val)
                    s.need(st, 2 + n)
                    args = st[-(2 + n):-2]
                    if all(e is not MANY and not e.mat and e.val is not None for e in args):
                        r = s.inline(s.funcs[nm.val[1]], vars_)
                        del st[-(2 + n):]
                        st.append(Entry(r, False)); pc = nxt; continue
                n = s.count_at(st, 2)
                s.real(st, c, op.data, 2 + n, 1); pc = nxt; continue
            if c in (0x52, 0x53):  # CallMethod / NewMethod
                n = s.count_at(st, 3)
                s.real(st, c, op.data, 3 + n, 1); pc = nxt; continue
            if c == 0x40:  # NewObject
                n = s.count_at(st, 2)
                s.real(st, c, op.data, 2 + n, 1); pc = nxt; continue
            if c == 0x42:  # InitArray
                n = s.count_at(st, 1)
                s.real(st, c, op.data, 1 + n, 1); pc = nxt; continue
            if c == 0x43:  # InitObject
                n = s.count_at(st, 1)
                s.real(st, c, op.data, 1 + 2 * n, 1); pc = nxt; continue
            if c == 0x2c:  # ImplementsOp
                n = s.count_at(st, 2)
                s.real(st, c, op.data, 2 + n, 0); pc = nxt; continue
            if c == 0x27:  # StartDrag
                s.need(st, 3)
                e = st[-3]
                if e is MANY or e.val is None: raise Bail('startDrag constraint unknown')
                s.real(st, c, op.data, 7 if to_bool(e.val) else 3, 0); pc = nxt; continue
            if c in (0x46, 0x55):  # Enumerate
                s.real(st, c, op.data, 1, 0)
                st.append(MANY); pc = nxt; continue
            if c == 0x87:  # StoreRegister
                s.need(st, 1)
                s.materialize(st); s.emit(c, op.data)
                pc = nxt; continue
            if c in (0x8f,):  # Try: blocks with sizes, not handled
                raise Bail('try block')
            if c == 0x94:  # With: body size
                raise Bail('with block')
            if c in (0x8a, 0x8d):
                raise Bail('waitForFrame')
            if c in FIXED:
                p, q = FIXED[c]
                s.real(st, c, op.data, p, q); pc = nxt; continue
            raise Bail('unknown op %02x at %d' % (c, pc))

    def run_fn(s, end):
        """a function body (start..end): code may leave it (trampolines) but that's fine"""
        s.end = end
        return s.run()

    def copy_plain(s, start, end, pool):
        raise Bail('nested function failed')

    def inline(s, fn, vars_):
        """run an obfuscator helper ("\\x04\\x05": set "\\x03", return it) on known values"""
        start, end, pool = fn
        st = []
        pc = start
        for _ in range(10000):
            op = read(s.b, pc); c = op.code; nxt = op.end
            if c == 0x96:
                for t, x in push_values(op.data, pool):
                    if t == 'pool': st.append(('str', pool[x]))
                    elif t in ('reg', 'bad'): raise Bail('helper reg')
                    else: st.append((t, x))
            elif c in PURE:
                n = PURE[c]; r = pure_op(c, st[-n:]); del st[-n:]; st.append(r)
            elif c == 0x1c:
                nm = st.pop()
                if not is_obf_name(nm[1]): raise Bail('helper reads ' + repr(nm))
                st.append(vars_.get(nm[1], UNDEF))
            elif c in (0x1d, 0x3c):
                v = st.pop(); nm = st.pop()
                if not is_obf_name(nm[1]): raise Bail('helper writes ' + repr(nm))
                vars_[nm[1]] = v
            elif c == 0x3e: return st.pop()
            elif c == 0x99: nxt = branch_target(op)
            elif c == 0x9d:
                if to_bool(st.pop()): nxt = branch_target(op)
            elif c == 0x17: st.pop()
            elif c == 0x00: return UNDEF
            else: raise Bail('helper op %02x' % c)
            pc = nxt
        raise Bail('helper loops')

    # -- stack helpers
    def need(s, st, n):
        have = 0
        for e in reversed(st):
            if e is MANY: return
            have += 1
            if have >= n: return
        if have < n:
            # stack underflow in the original: Flash pushes undefined; keep going with runtime values
            for _ in range(n - have): st.insert(0, Entry(UNDEF, False))

    def pop(s, st):
        s.need(st, 1)
        e = st.pop()
        if e is MANY: st.append(MANY); return Entry(None, True)
        return e

    def count_at(s, st, depth):
        s.need(st, depth)
        idx = len(st) - depth
        e = st[idx] if idx >= 0 else MANY
        if e is MANY or e.val is None: raise Bail('call with runtime arg count')
        n = to_i32(e.val)
        if n < 0 or n > 255: raise Bail('arg count %d' % n)
        return n

    def real(s, st, code, data, pops, pushes):
        s.need(st, pops)
        s.materialize(st)
        s.emit(code, data)
        for _ in range(pops):
            e = st.pop()
            if e is MANY: st.append(MANY); break
        for _ in range(pushes): st.append(Entry(None, True))

# ------------------------------------------------------------------ encoding
def enc_val(v, pool=None):
    t, x = v
    if t == 'str':
        if pool is not None and x in pool:
            k = pool[x]
            return bytes([8, k]) if k < 256 else b'\x09' + struct.pack('<H', k)
        return b'\x00' + x.encode('latin1') + b'\x00'
    if t == 'num':
        if x == int(x) and -2**31 <= x < 2**31 and not (x == 0 and math.copysign(1, x) < 0):
            return b'\x07' + struct.pack('<i', int(x))
        d = struct.pack('<d', x)
        return b'\x06' + d[4:] + d[:4]
    if t == 'bool': return b'\x05' + bytes([1 if x else 0])
    if t == 'null': return b'\x02'
    if t == 'undef': return b'\x03'
    if t == 'reg': return bytes([4, x])
    raise Bail('enc ' + t)

def count_strings(items, cnt):
    for it in items:
        if it[0] == 'push':
            for v in it[1]:
                if v[0] == 'str': cnt[v[1]] = cnt.get(v[1], 0) + 1
        elif it[0] == 'func': count_strings(it[3], cnt)

def make_pool(items):
    """one constant pool for the whole block (functions defined in it use it too)"""
    cnt = {}
    count_strings(items, cnt)
    order = sorted((k for k in cnt if cnt[k] > 1 or len(k) > 2), key=lambda k: (-cnt[k] * (len(k) + 1), k))
    pool = {}; size = 2
    for k in order:
        b = len(k.encode('latin1')) + 1
        if size + b > 65000 or len(pool) >= 65000: break
        pool[k] = len(pool); size += b
    return pool

def body_bytes(items, pool):
    """items -> bytes, resolving labels. Jumps/Ifs are 5 bytes."""
    enc = []
    for it in items:
        k = it[0]
        if k == 'push':
            d = b''.join(enc_val(v, pool) for v in it[1])
            enc.append(('raw', b'\x96' + struct.pack('<H', len(d)) + d))
        elif k == 'op':
            c, d = it[1], it[2]
            enc.append(('raw', bytes([c]) + (struct.pack('<H', len(d)) + d if c >= 0x80 else b'')))
        elif k == 'func':
            code = body_bytes(it[3], pool)
            hdr = it[2] + struct.pack('<H', len(code))
            enc.append(('raw', bytes([it[1]]) + struct.pack('<H', len(hdr)) + hdr + code))
        else:
            enc.append(it)
    pos = {}; at = 0
    for it in enc:
        if it[0] == 'label': pos[it[1]] = at
        elif it[0] == 'raw': at += len(it[1])
        else: at += 5
    out = bytearray()
    for it in enc:
        if it[0] == 'label': continue
        if it[0] == 'raw': out += it[1]; continue
        off = pos[it[1]] - (len(out) + 5)
        if not -32768 <= off < 32768: raise Bail('branch too far')
        out += bytes([0x99 if it[0] == 'jump' else 0x9d]) + struct.pack('<Hh', 2, off)
    return bytes(out)

def assemble(items):
    pool = make_pool(items)
    head = b''
    if pool:
        names = sorted(pool, key=pool.get)
        d = struct.pack('<H', len(names)) + b''.join(n.encode('latin1') + b'\x00' for n in names)
        head = b'\x88' + struct.pack('<H', len(d)) + d
    return head + body_bytes(items, pool)

def peephole(items):
    """remove jumps to the very next label"""
    out = []
    for i, it in enumerate(items):
        if it[0] == 'jump':
            j = i + 1
            nxt_labels = set()
            while j < len(items) and items[j][0] == 'label':
                nxt_labels.add(items[j][1]); j += 1
            if it[1] in nxt_labels: continue
        out.append(it)
    return out

def deob_block(buf, start, verbose=False):
    u = Unit(buf, start, None, verbose)
    items = u.run()
    if not items or items[-1] != ('op', 0, b''): items.append(('op', 0, b''))
    return assemble(peephole(items))

# ------------------------------------------------------------------ SWF rewriting
def load(p):
    d = open(p, 'rb').read()
    if d[:3] == b'CWS': d = b'FWS' + d[3:8] + zlib.decompress(d[8:])
    elif d[:3] == b'ZWS': raise SystemExit('LZMA SWF: not supported')
    return bytearray(d)

def tag_list(d, pos, end):
    out = []
    while pos < end:
        h = struct.unpack_from('<H', d, pos)[0]; code = h >> 6; ln = h & 63; p = pos + 2
        if ln == 63: ln = struct.unpack_from('<I', d, p)[0]; p += 4
        out.append((code, pos, p, ln))
        pos = p + ln
        if code == 0: break
    return out

def tag_bytes(code, body):
    if len(body) < 63 and code not in (6, 21, 35, 20, 36, 90):
        return struct.pack('<H', (code << 6) | len(body)) + body
    return struct.pack('<HI', (code << 6) | 63, len(body)) + body

class Bits:
    def __init__(s, d, p): s.d = d; s.p = p; s.bit = 0
    def ub(s, n):
        v = 0
        for _ in range(n):
            v = (v << 1) | ((s.d[s.p] >> (7 - s.bit)) & 1)
            s.bit += 1
            if s.bit == 8: s.bit = 0; s.p += 1
        return v
    def end(s): return s.p + (1 if s.bit else 0)

def skip_matrix(d, p):
    b = Bits(d, p)
    if b.ub(1): n = b.ub(5); b.ub(n); b.ub(n)
    if b.ub(1): n = b.ub(5); b.ub(n); b.ub(n)
    n = b.ub(5); b.ub(n); b.ub(n)
    return b.end()

def skip_cxform(d, p, alpha=True):
    b = Bits(d, p)
    ha = b.ub(1); hm = b.ub(1); n = b.ub(4)
    k = 4 if alpha else 3
    if hm: [b.ub(n) for _ in range(k)]
    if ha: [b.ub(n) for _ in range(k)]
    return b.end()

def deob_into(d, off, verbose, stats, what):
    try:
        nb_ = deob_block(d, off, verbose)
        stats['ok'] += 1
        return nb_
    except (Bail, RecursionError, IndexError, struct.error, ValueError, KeyError, UnicodeError) as e:
        stats['kept'] += 1
        print('%s at %d kept as is: %s' % (what, off, e))
        return None

def place_actions(d, p, ln, version, verbose, stats, po3=False):
    """PlaceObject2/3 with onClipEvent code: the tag with the code rewritten (or None)"""
    q = p
    f = d[q]; q += 1
    f2 = 0
    if po3: f2 = d[q]; q += 1
    if not f & 0x80: return None  # no clip actions
    q += 2  # depth
    if po3 and (f2 & 0x08 or (f2 & 0x10 and f & 0x02)): q = d.index(0, q) + 1  # class name
    if f & 0x02: q += 2
    if f & 0x04: q = skip_matrix(d, q)
    if f & 0x08: q = skip_cxform(d, q)
    if f & 0x10: q += 2
    if f & 0x20: q = d.index(0, q) + 1
    if f & 0x40: q += 2
    if po3 and f2 & 0x01: return None  # filters: not parsed
    if po3 and f2 & 0x02: q += 1
    if po3 and f2 & 0x04: q += 1
    out = bytearray(d[p:q])
    w = 4 if version >= 6 else 2
    out += d[q:q + 2 + w]; q += 2 + w
    end = p + ln
    while q < end:
        flags = d[q:q + w]; q += w
        if not any(flags):
            out += flags; break
        size = struct.unpack_from('<I', d, q)[0]; q += 4
        code_at = q; key = b''
        if w == 4 and flags[2] & 0x02:  # keyPress: key code first
            key = bytes([d[q]]); code_at = q + 1
        nb_ = deob_into(d, code_at, verbose, stats, 'clip event')
        body = key + (nb_ if nb_ is not None else bytes(d[code_at:q + size]))
        out += flags + struct.pack('<I', len(body)) + body
        q += size
    out += d[q:end]
    return bytes(out)

def button2_actions(d, p, ln, verbose, stats):
    q = p + 3
    off = struct.unpack_from('<H', d, q)[0]
    if not off: return None
    a = q + off
    out = bytearray(d[p:a])
    end = p + ln
    while a < end:
        size = struct.unpack_from('<H', d, a)[0]
        cond = d[a + 2:a + 4]
        stop = a + size if size else end
        nb_ = deob_into(d, a + 4, verbose, stats, 'button action')
        body = nb_ if nb_ is not None else bytes(d[a + 4:stop])
        out += struct.pack('<H', (4 + len(body)) if size else 0) + cond + body
        if not size: break
        a = stop
    return bytes(out)

def rewrite(d, verbose):
    nb = d[8] >> 3; hdr = 8 + (5 + nb * 4 + 7) // 8 + 4
    stats = {'ok': 0, 'kept': 0}
    def conv(tags):
        out = bytearray()
        for code, tpos, p, ln in tags:
            body = bytes(d[p:p + ln])
            if code == 12 or code == 59:
                off = p + (2 if code == 59 else 0)
                try:
                    nb_ = deob_block(d, off, verbose)
                    body = (body[:2] if code == 59 else b'') + nb_
                    stats['ok'] += 1
                    if verbose: print('block at %d (%s): %d -> %d bytes' % (off, 'init' if code == 59 else 'frame', ln, len(body)))
                except (Bail, RecursionError, IndexError, struct.error, ValueError, KeyError, UnicodeError) as e:
                    stats['kept'] += 1
                    print('block at %d kept as is: %s' % (off, e))
                out += tag_bytes(code, body)
            elif code in (26, 70) and (d[p] & 0x80):
                try: nbody = place_actions(d, p, ln, d[3], verbose, stats, code == 70)
                except (IndexError, struct.error, ValueError) as e:
                    print('PlaceObject at %d not parsed: %s' % (p, e)); nbody = None
                out += tag_bytes(code, nbody) if nbody is not None else d[tpos:p + ln]
            elif code == 34:
                try: nbody = button2_actions(d, p, ln, verbose, stats)
                except (IndexError, struct.error, ValueError) as e:
                    print('button at %d not parsed: %s' % (p, e)); nbody = None
                out += tag_bytes(code, nbody) if nbody is not None else d[tpos:p + ln]
            elif code == 39:
                sub = tag_list(d, p + 4, p + ln)
                out += tag_bytes(39, body[:4] + bytes(conv(sub)))
            else:
                out += d[tpos:p + ln]
        return out
    body = conv(tag_list(d, hdr, len(d)))
    res = bytearray(d[:hdr]) + body
    res[0:3] = b'FWS'
    struct.pack_into('<I', res, 4, len(res))
    return res, stats

if __name__ == '__main__':
    sys.setrecursionlimit(5000)
    verbose = '-v' in sys.argv
    args = [a for a in sys.argv[1:] if a != '-v']
    d = load(args[0])
    res, st = rewrite(d, verbose)
    open(args[1], 'wb').write(res)
    print('blocks rewritten %d, kept %d -> %s' % (st['ok'], st['kept'], args[1]))
