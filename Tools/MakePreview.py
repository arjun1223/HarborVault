"""Draw documentation artwork from fictional labels; no files or UI are read."""
from pathlib import Path
from html import escape
parts=['''<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="800" viewBox="0 0 1280 800" role="img" aria-labelledby="title desc">
<title id="title">Harbor Vault illustrated demo workspace</title>
<desc id="desc">A code-drawn light file browser. All names and document thumbnails are fictional. This is not a screenshot.</desc>
<rect width="1280" height="800" fill="#edece8"/>
<defs><clipPath id="window"><rect x="36" y="32" width="1208" height="728" rx="24"/></clipPath></defs>
<g clip-path="url(#window)"><rect x="36" y="32" width="1208" height="728" fill="#fafaf8"/><rect x="36" y="32" width="238" height="728" fill="#f0f0ed"/><path d="M274 32V760" stroke="#deded8"/></g>
<rect x="36.5" y="32.5" width="1207" height="727" rx="24" fill="none" stroke="#d4d4ce"/>''']
def rect(x,y,w,h,fill,r=0,stroke=None):
    parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}"'+(f' stroke="{stroke}"' if stroke else '')+'/>')
def text(x,y,value,size=14,fill='#2b2c2d',weight=400):
    parts.append(f'<text x="{x}" y="{y}" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="{size}" font-weight="{weight}" fill="{fill}">{escape(value)}</text>')
def line(x,y,w,color='#dcdcd5'):
    parts.append(f'<path d="M{x} {y}h{w}" stroke="{color}"/>')
for x,c in [(61,'#ef615a'),(82,'#e9ba48'),(103,'#64bd74')]:parts.append(f'<circle cx="{x}" cy="57" r="6" fill="{c}"/>')
rect(60,97,40,40,'#292b2d',12);rect(69,109,22,16,'#e6a638',3);rect(69,105,9,8,'#e6a638',2)
text(112,117,'Harbor',23,weight=700);text(112,136,'Private file storage',11,'#7a7b76')
rect(53,170,203,44,'#e7e5df',12);text(70,198,'▦',18);text(104,198,'Files',14,weight=600)
text(71,241,'⌫',17,'#72746e');text(104,241,'Recently Deleted',13,'#696b65');text(65,296,'VAULTS',10,'#7d7e78',600)
rect(53,312,203,44,'#fff',12,'#e0e0d9');text(70,340,'▣',16,'#797b74');text(104,340,'Demo vault',13,weight=600)
parts.append('<circle cx="235" cy="335" r="3" fill="#5d936f"/>')
text(70,385,'▣',16,'#797b74');text(104,385,'Sample vault',13,'#777970')
rect(57,631,196,66,'#f8f8f5',13);text(71,657,'Stored on this Mac',12,weight=600);text(71,678,'Encrypted while locked',11,'#7a7c74')
text(70,734,'⚙',16,'#777970');text(104,734,'Preferences',12,'#6b6d65')
text(306,102,'Files',27,weight=650);text(306,128,'Demo vault',12,'#74766e')
rect(1030,82,182,31,'#f0eee8',10);text(1044,102,'DEMO WORKSPACE',10,'#73746c',600)
line(274,153,970,'#e2e2dc');text(306,187,'‹',24,'#777970');text(340,187,'›',24,'#b2b4ac');text(382,185,'All files',12,weight=600)
rect(306,213,257,37,'#fff',11,'#dfdfd7');text(322,237,'⌕',19,'#7e8078');text(349,236,'Search filenames',12,'#92948b')
rect(773,213,72,37,'#eeefe9',11);text(786,238,'☷',18,'#87897f');rect(808,217,32,29,'#fff',8);text(816,237,'▦',17)
rect(860,213,44,37,'#fff',11,'#dfdfd7');text(875,237,'↑',17)
rect(916,213,126,37,'#fff',11,'#dfdfd7');text(934,236,'+  New folder',12)
rect(1054,213,158,37,'#e9aa3a',11);text(1101,236,'+  Import',12,weight=600)
cards=[('Travel notes.txt','Text document','text'),('Example receipt.pdf','PDF document','pdf'),('Sample image.png','Image · illustration','image'),('Reading list.md','Markdown document','text')]
for index,(name,kind,style) in enumerate(cards):
    x=306+index*230;selected=index==1
    rect(x,284,216,254,'#eee8da' if selected else '#fff',16,'#d2bb8e' if selected else '#e3e3dc');rect(x+15,299,186,167,'#f5f5f0',11)
    if style=='image':
        rect(x+46,323,124,110,'#e1e7df',9);parts.append(f'<circle cx="{x+141}" cy="347" r="11" fill="#edc56d"/>');parts.append(f'<path d="M{x+46} 413l38 -46 24 29 22 -18 40 35v20H{x+46}z" fill="#94a58f"/>')
    else:
        rect(x+61,315,94,132,'#fff',5,'#e0e1d9');rect(x+73,333,42,5,'#dfbd7b' if style=='pdf' else '#b4c1ad',2)
        for row,w in enumerate([68,61,68,47,68,57,64]):rect(x+73,351+row*10,w,3,'#d9dcd3',1)
        if style=='pdf':text(x+73,431,'PDF',9,'#9a8151',600)
    text(x+15,493,name,12,weight=600);text(x+15,514,kind,10,'#7a7c73')
line(274,706,970,'#e1e1d9');text(307,738,'4 demo files · Illustrated preview',11,'#7b7d73')
text(1024,737,'−',13,'#7c7e75');line(1048,732,123,'#c4c8bc');parts.append('<circle cx="1111" cy="732" r="5" fill="#9a9f91"/>');text(1188,737,'+',14,'#7c7e75')
text(429,785,'DRAWN FROM CODE · FICTIONAL FILENAMES · NO PERSONAL FILES',10,'#85877e',500);parts.append('</svg>')
output=Path(__file__).resolve().parent.parent/'assets/previews/workspace.svg';output.parent.mkdir(parents=True,exist_ok=True);output.write_text('\n'.join(parts)+'\n');print('Generated assets/previews/workspace.svg')
