# usage: python3 -I judge-features.py OWNER/REPO NUMBER [TRAIN_START_ISO]
#   -> JSON of the review-train features at the latest 5-round checkpoint.
#   TRAIN_START_ISO is the oracle's train_start; rounds before it belong to an earlier train.
import json, os, re, subprocess, sys, collections
from datetime import datetime
# gh through address-pr-comments/bin/gh, which files each request into the call log
GH=os.path.join(os.path.dirname(os.path.realpath(__file__)),'..','address-pr-comments','bin','gh')
GH=GH if os.access(GH,os.X_OK) else 'gh'
repo,num=sys.argv[1],int(sys.argv[2]); o,n=repo.split('/')
since=sys.argv[3] if len(sys.argv)>3 and sys.argv[3] not in ('','null') else None
BOT='chatgpt-codex-connector'
Q='''query($o:String!,$n:String!,$num:Int!,$c:String){repository(owner:$o,name:$n){pullRequest(number:$num){changedFiles
 reviews(first:100,after:$c){pageInfo{hasNextPage endCursor} nodes{id author{login} submittedAt}}}}}'''
QT='''query($o:String!,$n:String!,$num:Int!,$c:String){repository(owner:$o,name:$n){pullRequest(number:$num){
 reviewThreads(first:100,after:$c){pageInfo{hasNextPage endCursor} nodes{path comments(first:1){nodes{author{login} createdAt body pullRequestReview{id}}}}}}}}'''
QC='''query($o:String!,$n:String!,$num:Int!,$c:String){repository(owner:$o,name:$n){pullRequest(number:$num){
 comments(first:100,after:$c){pageInfo{hasNextPage endCursor} nodes{author{login} createdAt body}}}}}'''
def pages(q,key):
    out=[];c=None;pr=None
    while True:
        a=[GH,'api','graphql','-f',f'query={q}','-f',f'o={o}','-f',f'n={n}','-F',f'num={num}']+(['-f',f'c={c}'] if c else [])
        pr=json.loads(subprocess.run(a,capture_output=True,text=True,check=True).stdout)['data']['repository']['pullRequest']
        out+=pr[key]['nodes']
        if not pr[key]['pageInfo']['hasNextPage']: return out,pr
        c=pr[key]['pageInfo']['endCursor']
ts=lambda s: datetime.fromisoformat(s.replace('Z','+00:00'))
# same normalization and clean-reply phrase as pr-state.sh, so both count the same rounds
au=lambda a:(a or {}).get('login','').lower().removesuffix('[bot]')
revs,pr=pages(Q,'reviews'); threads,_=pages(QT,'reviewThreads'); comments,_=pages(QC,'comments')
# Same rule as pr-state.sh: sort reviews and clean replies together; a row < 300s after the
# previous row joins its round (chained). A round is "clean" only if it holds no review.
since_t=ts(since) if since else None
ev=sorted([(ts(r['submittedAt']),False,r['id']) for r in revs if au(r['author'])==BOT and r['submittedAt']]+
          [(ts(c['createdAt']),True,None) for c in comments if au(c['author'])==BOT and re.search(r"codex review: didn.t find any major issues",c['body'] or '',re.I)])
ev=[e for e in ev if not since_t or e[0]>since_t]
rs=[];prev=None;round_of={}
for t,cl,rid in ev:
    if not (prev and (t-prev).total_seconds()<300): rs.append((t,cl))
    else: rs[-1]=(rs[-1][0],rs[-1][1] and cl)
    if rid: round_of[rid]=len(rs)-1
    prev=t
F=[]
for th in threads:
    c=th['comments']['nodes'][0] if th['comments']['nodes'] else None
    # a finding belongs to the round of the review it was posted in; earlier trains drop out
    rid=((c or {}).get('pullRequestReview') or {}).get('id')
    if not c or au(c['author'])!=BOT or rid not in round_of: continue
    r=round_of[rid]
    m=re.search(r'badge/P([0-3])-',c['body'] or ''); F.append(dict(r=r,path=th['path'],sev=int(m.group(1)) if m else 9))
k=len(rs)//5*5; W=[f for f in F if k-5<=f['r']<k]
files=collections.Counter(f['path'] for f in W)
print(json.dumps(dict(rounds=len(rs),checkpoint=k,window_findings=len(W),window_p1=sum(f['sev']==1 for f in W),
    md_findings=sum(f['path'].endswith('.md') for f in W),
    md_share=sum(f['path'].endswith('.md') for f in W)/len(W) if W else 0,
    file_spread=round(len(files)/max(1,pr['changedFiles']),2),top_files=files.most_common(3))))
