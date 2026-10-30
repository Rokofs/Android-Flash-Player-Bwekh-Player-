"""Interfaces of classes as Multiname(name, [ns]) like Flash/Flex compilers emit them (Royale writes QNames).
New multiname entries are appended and only the interface lists point at them: the QName itself stays,
since it also names the interface and its traits (a Multiname there is VerifyError #1033)."""
import sys,zlib,struct
import os; src=open(os.path.join(os.path.dirname(os.path.abspath(__file__)),'abcp.py')).read()
ns={}; exec(src,ns)
R=ns['R']
def wu30(v):
    out=bytearray()
    while True:
        b=v&0x7f; v>>=7
        if v: out.append(b|0x80)
        else: out.append(b); return bytes(out)
def skip_traits(r):
    c=r.u30()
    for i in range(c):
        r.u30(); k=r.u8(); kind=k&0xf
        if kind in (0,6):
            r.u30(); r.u30(); vi=r.u30()
            if vi: r.u8()
        elif kind in (1,2,3,4,5): r.u30(); r.u30()
        else: raise Exception('trait kind %d'%kind)
        if k&0x40:
            c2=r.u30(); [r.u30() for j in range(c2)]
def fix_abc(a):
    d=ns['parse'](a); mns=d['mns']
    r=R(a); r.p=4
    n=r.u30(); [r.u30() for i in range(1,n)]
    n=r.u30(); [r.u30() for i in range(1,n)]
    n=r.u30(); r.p+=8*max(0,n-1)
    n=r.u30()
    for i in range(1,n): l=r.u30(); r.p+=l
    n=r.u30()
    for i in range(1,n): r.u8(); r.u30()
    nsset_start=r.p
    n=r.u30(); nssets=[None]
    for i in range(1,n):
        c=r.u30(); nssets.append([r.u30() for j in range(c)])
    n=r.u30(); raw=[None]
    for i in range(1,n):
        st=r.p; k=r.u8()
        if k in (7,0xd,9,0xe): r.u30(); r.u30()
        elif k in (0xf,0x10,0x1b,0x1c): r.u30()
        elif k in (0x11,0x12): pass
        elif k==0x1d:
            q=r.u30(); c=r.u30(); [r.u30() for j in range(c)]
        raw.append(a[st:r.p])
    mn_end=r.p
    # methods, metadata: unchanged
    mc=r.u30()
    for i in range(mc):
        pc=r.u30(); r.u30(); [r.u30() for j in range(pc)]; r.u30(); f=r.u8()
        if f&8:
            c=r.u30()
            for j in range(c): r.u30(); r.u8()
        if f&0x80: [r.u30() for j in range(pc)]
    md=r.u30()
    for i in range(md):
        r.u30(); c=r.u30(); [r.u30() for j in range(2*c)]
    mid_end=r.p
    newsets={}; remap={}
    insts=bytearray(); cc=r.u30(); insts+=wu30(cc); count=0
    for i in range(cc):
        nm=r.u30(); sup=r.u30(); f=r.u8()
        insts+=wu30(nm)+wu30(sup)+bytes([f])
        if f&8: insts+=wu30(r.u30())
        c=r.u30(); insts+=wu30(c)
        for j in range(c):
            x=r.u30()
            if mns[x][0]==7:
                if x not in remap:
                    k,nsi,name=mns[x]
                    if nsi not in newsets:
                        nssets.append([nsi]); newsets[nsi]=len(nssets)-1
                    raw.append(bytes([9])+wu30(name)+wu30(newsets[nsi])); remap[x]=len(raw)-1
                x=remap[x]; count+=1
            insts+=wu30(x)
        insts+=wu30(r.u30())
        st=r.p; skip_traits(r); insts+=a[st:r.p]
    if not count: return a,0
    out=bytearray(a[:nsset_start])
    out+=wu30(len(nssets))
    for s in nssets[1:]: out+=wu30(len(s))+b''.join(wu30(v) for v in s)
    out+=wu30(len(raw))
    for m in raw[1:]: out+=m
    out+=a[mn_end:mid_end]+insts+a[r.p:]
    return bytes(out),count
d=open(sys.argv[1],'rb').read()
if d[:3]==b'CWS': d=b'FWS'+d[3:8]+zlib.decompress(d[8:])
nb=d[8]>>3; p=8+(5+4*nb+7)//8+4
out=bytearray(d[:p]); total=0
while p<len(d):
    h=struct.unpack_from('<H',d,p)[0]; c=h>>6; l=h&63; q=p+2
    if l==63: l=struct.unpack_from('<I',d,q)[0]; q+=4
    body=d[q:q+l]
    if c==82:
        z=body.index(b'\0',4)+1
        na,cnt=fix_abc(body[z:]); total+=cnt
        body=body[:z]+na
        out+=struct.pack('<HI',(c<<6)|63,len(body))+body
    else:
        out+=d[p:q+l]
    p=q+l
    if c==0: break
struct.pack_into('<I',out,4,len(out))
open(sys.argv[2],'wb').write(out)
print('interfaces rewritten',total)
