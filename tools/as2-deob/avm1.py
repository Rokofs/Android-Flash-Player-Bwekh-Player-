"""AVM1 bytecode: parse / disassemble / assemble."""
import struct
NAMES={0x00:'End',0x04:'NextFrame',0x05:'PrevFrame',0x06:'Play',0x07:'Stop',0x08:'ToggleQuality',0x09:'StopSounds',
0x0a:'Add',0x0b:'Subtract',0x0c:'Multiply',0x0d:'Divide',0x0e:'Equals',0x0f:'Less',0x10:'And',0x11:'Or',0x12:'Not',
0x13:'StringEquals',0x14:'StringLength',0x15:'StringExtract',0x17:'Pop',0x18:'ToInteger',0x1c:'GetVariable',0x1d:'SetVariable',
0x20:'SetTarget2',0x21:'StringAdd',0x22:'GetProperty',0x23:'SetProperty',0x24:'CloneSprite',0x25:'RemoveSprite',0x26:'Trace',
0x27:'StartDrag',0x28:'EndDrag',0x29:'StringLess',0x2a:'Throw',0x2b:'CastOp',0x2c:'ImplementsOp',0x30:'RandomNumber',
0x31:'MBStringLength',0x32:'CharToAscii',0x33:'AsciiToChar',0x34:'GetTime',0x35:'MBStringExtract',0x36:'MBCharToAscii',
0x37:'MBAsciiToChar',0x3a:'Delete',0x3b:'Delete2',0x3c:'DefineLocal',0x3d:'CallFunction',0x3e:'Return',0x3f:'Modulo',
0x40:'NewObject',0x41:'DefineLocal2',0x42:'InitArray',0x43:'InitObject',0x44:'TypeOf',0x45:'TargetPath',0x46:'Enumerate',
0x47:'Add2',0x48:'Less2',0x49:'Equals2',0x4a:'ToNumber',0x4b:'ToString',0x4c:'PushDuplicate',0x4d:'StackSwap',
0x4e:'GetMember',0x4f:'SetMember',0x50:'Increment',0x51:'Decrement',0x52:'CallMethod',0x53:'NewMethod',0x54:'InstanceOf',
0x55:'Enumerate2',0x60:'BitAnd',0x61:'BitOr',0x62:'BitXor',0x63:'BitLShift',0x64:'BitRShift',0x65:'BitURShift',
0x66:'StrictEquals',0x67:'Greater',0x68:'StringGreater',0x69:'Extends',
0x81:'GotoFrame',0x83:'GetURL',0x87:'StoreRegister',0x88:'ConstantPool',0x8a:'WaitForFrame',0x8b:'SetTarget',0x8c:'GoToLabel',
0x8d:'WaitForFrame2',0x8e:'DefineFunction2',0x8f:'Try',0x94:'With',0x96:'Push',0x99:'Jump',0x9a:'GetURL2',0x9b:'DefineFunction',
0x9d:'If',0x9e:'Call',0x9f:'GotoFrame2'}

def cstr(b,p):
    e=b.index(0,p); return b[p:e].decode('latin1'),e+1

class Op:
    __slots__=('pc','code','data','size')
    def __init__(s,pc,code,data):
        s.pc=pc; s.code=code; s.data=data; s.size=(3+len(data) if code>=0x80 else 1)
    @property
    def name(s): return NAMES.get(s.code,'Op%02x'%s.code)
    @property
    def end(s): return s.pc+s.size

def read(b,pc):
    """the action at absolute offset pc of buffer b"""
    code=b[pc]
    if code<0x80: return Op(pc,code,b'')
    ln=struct.unpack_from('<H',b,pc+1)[0]
    return Op(pc,code,bytes(b[pc+3:pc+3+ln]))

def push_values(data,pool):
    """Push operands: list of ('str'|'num'|'bool'|'null'|'undef'|'reg', value)"""
    out=[];p=0
    while p<len(data):
        t=data[p];p+=1
        if t==0: s,p=cstr(data,p); out.append(('str',s))
        elif t==1: out.append(('num',struct.unpack_from('<f',data,p)[0]));p+=4
        elif t==2: out.append(('null',None))
        elif t==3: out.append(('undef',None))
        elif t==4: out.append(('reg',data[p]));p+=1
        elif t==5: out.append(('bool',bool(data[p])));p+=1
        elif t==6:
            hi,lo=struct.unpack_from('<II',data,p);p+=8
            out.append(('num',struct.unpack('<d',struct.pack('<II',lo,hi))[0]))
        elif t==7: out.append(('num',struct.unpack_from('<i',data,p)[0]));p+=4
        elif t==8: i=data[p];p+=1; out.append(('pool',i))
        elif t==9: i=struct.unpack_from('<H',data,p)[0];p+=2; out.append(('pool',i))
        else: out.append(('bad',t)); break
    return out

def parse_pool(data):
    n=struct.unpack_from('<H',data,0)[0];p=2;r=[]
    for _ in range(n): s,p=cstr(data,p); r.append(s)
    return r

def branch_target(op):
    return op.end+struct.unpack('<h',op.data[:2])[0]

def func_info(op):
    """DefineFunction(2): (name, params, body_len, header_end_len)"""
    d=op.data
    name,p=cstr(d,0)
    n=struct.unpack_from('<H',d,p)[0];p+=2
    params=[]
    if op.code==0x9b:
        for _ in range(n): s,p=cstr(d,p); params.append(s)
        flags=None; regs=0
    else:
        regs=d[p];p+=1; flags=struct.unpack_from('<H',d,p)[0];p+=2
        for _ in range(n):
            r=d[p];p+=1; s,p=cstr(d,p); params.append((r,s))
    blen=struct.unpack_from('<H',d,p)[0]
    return name,params,blen,regs,flags

def fmt_val(v,pool):
    t,x=v
    if t=='str': return repr(x)
    if t=='pool': return 'pool[%d]=%r'%(x,pool[x]) if pool and x<len(pool) else 'pool[%d]'%x
    if t=='reg': return 'r%d'%x
    if t in('null','undef'): return t
    return repr(x)

def disasm_op(op,pool):
    n=op.name
    if op.code==0x96: return n+' '+', '.join(fmt_val(v,pool) for v in push_values(op.data,pool))
    if op.code in(0x99,0x9d): return '%s -> %d'%(n,branch_target(op))
    if op.code==0x88: return n+' %d strings'%len(parse_pool(op.data))
    if op.code in(0x9b,0x8e):
        nm,pa,bl,_,_=func_info(op); return '%s %r(%s) body %d'%(n,nm,pa,bl)
    if op.code==0x87: return n+' r%d'%op.data[0]
    if op.data: return n+' '+op.data.hex()
    return n
