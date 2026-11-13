# Builds a made-up music library for README screenshots: silent FLACs with
# invented artists, albums and genres, a few playlists, and one audible,
# synthesized song ("Saltwater Radio") for the player to really play.
# Usage: python3 Tools/fakelibrary.py <folder>; see AGENTS.md "Screenshots".
import subprocess, os, json, random, sys
root=sys.argv[1]; music=os.path.join(root,'Music'); data=os.path.join(root,'data')
os.makedirs(music,exist_ok=True); os.makedirs(data,exist_ok=True)
random.seed(7)
cat=[
 ("Velvet Harbor","Low Tide Letters",2021,"Indie Rock",["Saltwater Radio","Paper Lanterns","Northbound","Glass Pier","The Long Swell","Harbor Lights","Undertow"]),
 ("Velvet Harbor","Static Coast",2018,"Indie Rock",["Coastline Static","Polaroid Summer","Lighthouse Keeper","Fog Machine","Drift"]),
 ("Mira Solano","Copper Skies",2023,"Jazz",["Copper Skies","Blue Hour Waltz","Midnight Tram","Silver Brush","Late Set"]),
 ("The Gravel Saints","Dust & Daylight",2016,"Country",["Dust & Daylight","Two-Lane Prayer","Porch Light","Rust Belt Rain","Gravel Road Hymn","Last Call in Abilene"]),
 ("Neon Orchard","Afterglow Machines",2024,"Electronic",["Afterglow","Synthetic Bloom","Night Bus","Pixel Rain","Chrome Garden","Afterglow (Reprise)"]),
 ("Neon Orchard","Soft Circuits",2020,"Electronic",["Soft Circuit","Moth to the Monitor","Dial Tone Lullaby","Overclock"]),
 ("Hollow Pines","Ember Season",2019,"Folk",["Ember Season","Cabin Fever","Wool & Woodsmoke","The Quiet Ridge","Kindling"]),
 ("Juno Vale","Bright Machinery",2022,"Pop",["Bright Machinery","Heartbeat Satellite","Sugar Static","Weekend Engine","Neon Valentine"]),
 ("Ironwood Collective","Basalt",2017,"Metal",["Basalt","Tectonic","Obsidian Crown","Magma Choir"]),
 ("Lena Ashgrove","Quiet Rooms",2025,"Classical",["Prelude in Grey","Window Etude","Nocturne for Rain","Quiet Rooms"]),
]
paths={}
for artist,album,year,genre,songs in cat:
  d=os.path.join(music,artist,album); os.makedirs(d,exist_ok=True)
  for n,t in enumerate(songs,1):
    f=os.path.join(d,"%02d %s.flac"%(n,t.replace('/','-')))
    dur=random.randint(150,330)
    if not os.path.exists(f):
      subprocess.run(['ffmpeg','-loglevel','error','-f','lavfi','-i','anullsrc=r=44100:cl=stereo','-t',str(dur),'-c:a','flac',
        '-metadata','title='+t,'-metadata','artist='+artist,'-metadata','album='+album,'-metadata','date=%d'%year,
        '-metadata','genre='+genre,'-metadata','track=%d'%n,f],check=True)
    paths.setdefault(artist,[]).append(f)
# Library: folder only; the app scans it.
json.dump({"folders":["file://"+music.replace(' ','%20')+"/"],"tracks":[],"schema":3},open(os.path.join(data,'library.json'),'w'))
import uuid
fav=[paths["Velvet Harbor"][0],paths["Mira Solano"][1],paths["Neon Orchard"][0],paths["Juno Vale"][1],paths["Hollow Pines"][3]]
road=paths["The Gravel Saints"][:4]+paths["Velvet Harbor"][2:5]+paths["Juno Vale"][:2]
late=paths["Mira Solano"]+paths["Lena Ashgrove"][:3]
pl=[{"id":"FA0E17E5-0000-4000-8000-00000000F4B5","name":"Favorites","paths":fav,"created":0},
    {"id":str(uuid.uuid4()).upper(),"name":"Road Trip","paths":road,"created":1},
    {"id":str(uuid.uuid4()).upper(),"name":"Late Night","paths":late,"created":2},
    {"id":str(uuid.uuid4()).upper(),"name":"Workout","paths":paths["Ironwood Collective"]+paths["Neon Orchard"][1:4],"created":3}]
json.dump(pl,open(os.path.join(data,'playlists.json'),'w'))
print(sum(len(v) for v in paths.values()),"songs")
CH='st(0,floor(mod(t,8)/2)); st(1,if(eq(ld(0),0),220,if(eq(ld(0),1),174.61,if(eq(ld(0),2),261.63,196))))'
PAD='+'.join('%g*sin(2*PI*ld(1)*%g*t)'%(a,m) for a,m in [(0.06,1),(0.05,1.26),(0.05,1.5),(0.035,2),(0.03,3),(0.025,4),(0.02,6),(0.015,8),(0.012,12),(0.01,16)])
LEAD='0.04*sin(2*PI*ld(1)*4*(1+0.5*floor(mod(t*4,4))/4)*t)*exp(-6*mod(t,0.25))'
EXPR=CH+'; '+PAD+'+'+LEAD+'+0.14*sin(2*PI*ld(1)/4*t)+0.45*sin(2*PI*55*t)*exp(-18*mod(t,0.5))+0.22*(random(0)-0.5)*exp(-30*mod(t+0.25,0.5))+0.08*(random(1)-0.5)*exp(-60*mod(t,0.125))'
song=os.path.join(music,"Velvet Harbor","Low Tide Letters","01 Saltwater Radio.flac")
subprocess.run(['ffmpeg','-y','-loglevel','error','-f','lavfi','-i',"aevalsrc=exprs='%s|%s':s=44100:d=214"%(EXPR,EXPR),
  '-af','aecho=0.6:0.4:120:0.25,volume=0.8','-c:a','flac','-metadata','title=Saltwater Radio','-metadata','artist=Velvet Harbor',
  '-metadata','album=Low Tide Letters','-metadata','date=2021','-metadata','genre=Indie Rock','-metadata','track=1',song],check=True)
print("playing song:",song)

# Synced lyrics for the audible song: invented words, one line about every six
# seconds, in an .lrc file beside it (this is also how real lyrics are found).
lines=["Switch on the radio, let the salt air in","The harbor's got a signal and it's calling me again",
"Paper lanterns drifting past the pier","Every little wave is spelling out your name","",
"Low tide letters on the shore","Say what you came here to say","Carry me back past the lighthouse door","Before the morning takes the bay","",
"Saltwater radio, tune me in","Static on the water, soft and thin","Play the song we never finished","Till the tide forgets where it begins","",
"Northbound lights across the sound","Counting every mile that I have found","Hold the line, keep the dial low","There's a signal where the quiet goes","",
"Saltwater radio, tune me in","Static on the water, soft and thin","Play the song we never finished","Till the tide forgets where it begins","",
"And when the last light folds away","I'll still be humming what you used to play","Saltwater radio, carry on","Carry on until the dawn"]
t=6.0; out=["[ar:Velvet Harbor]","[ti:Saltwater Radio]","[al:Low Tide Letters]"]
for l in lines:
  out.append("[%02d:%05.2f]%s"%(int(t//60),t%60,l)); t+=3.0 if l=="" else 6.2
open(song.rsplit('.',1)[0]+'.lrc','w').write("\n".join(out)+"\n")
print("lyrics written")
