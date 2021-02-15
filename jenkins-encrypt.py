#!/usr/bin/python
import re, sys
from os.path import expanduser, exists, join, dirname, abspath
from os import getcwd
from hashlib import md5
from commands import getstatusoutput as run_cmd

def cmd(cmd2run):
  e, o = run_cmd(cmd2run)
  if e:
    print o
    sys.exit(1)
  return o

def convert_string(xtype, passfile, data):
  return cmd("echo -n '%s' | openssl enc %s -md sha256 -a -base64 -aes-256-cbc -salt -pass file:%s" % (data, xtype, passfile)).strip('\n')

def convert_file(xtype, passfile, infile, outfile):
  cmd("openssl enc %s -md sha256 -a -base64 -aes-256-cbc -salt -in '%s' -out '%s.tmp' -pass file:%s" % (xtype, infile, outfile, passfile))
  cmd ("mv '%s.tmp' '%s'" % (outfile, outfile))
  return True

def process(opts, infiles):
  if not opts.decrypt:
    search = []
    for v in opts.values:   search.append(re.compile(v, re.I))
    for k in opts.keywords: search.append(re.compile('^(\s*<%s>)([^<]*)(</%s>\s*)' % (k,k),re.I))
    msearch = {}
    for k in opts.mkeywords:
      search.append(re.compile('^(\s*<(%s)>)(.*)' % k,re.I))
      msearch[k] = re.compile('^(.*)(</%s>\s*)' % k,re.I)
    opts.keywords = search
    opts.mkeywords = msearch
  cwd = abspath(getcwd())+"/"
  for infile in [abspath(f) for f in infiles]:
    if not infile.startswith(cwd):
      print "ERROR: Invalid file, not available in current working directory: ",infile
      sys.exit(1)
    infile = infile.replace(cwd, "")
    cdir = '%s/%s' % (opts.cache_dir, infile)
    res = 0
    if opts.decrypt: res = do_dec(opts, infile, cdir)
    else:            res = do_enc(opts, infile, cdir)
    if res>0: print "Processed ",res,infile

def do_enc(opts, infile, cdir):
  efile = join(cdir,'data')
  sfile = join(cdir,'cksum')
  dfile = join(cdir,'config')
  ncksum = cmd("sha256sum -b '%s' | sed 's| .*||'" % infile).strip('\n')
  if not opts.force and exists(sfile):
    ocksum = ""
    with open(sfile) as ref:
      ocksum = ref.readline().strip('\n')
    if (ncksum==ocksum) and exists(efile):
      cmd("cp -f '%s' '%s'" % (efile, infile))
      return -1
  if not opts.partial:
    convert_file('-e', opts.passfile, infile, infile)
    cmd("mkdir -p '%s' && cp -f '%s' '%s' && echo '%s' > '%s'" % (cdir, infile, efile, ncksum, sfile))
    return 1
  mnum=0
  data=[]
  lines = []
  xfile = open(infile)
  mdata=["","",""]
  for l in xfile.readlines():
    if mdata[0]:
      m = opts.mkeywords[mdata[0]].match(l)
      if not m:
        mdata[2]+=l
        continue
      mdata[2]+=m.group(1)
      mdata[0]=""
      data.append(convert_string('-e',opts.passfile,mdata[2]))
      lines.append("%s@JENKINS_BACKUP_%s@%s" % (mdata[1],mnum,m.group(2)))
      mnum+=1
      continue
    for exp in opts.keywords:
      m = exp.match(l)
      if m:
        if m.group(2) in opts.mkeywords:
          mdata = [m.group(2),m.group(1),m.group(3)+'\n']
        elif (m.group(2)!=''):
          x=[]
          data.append(convert_string('-e',opts.passfile,m.group(2)))
          l='%s@JENKINS_BACKUP_%s@%s' % (m.group(1),mnum,m.group(3))
          mnum+=1
        break
    if mdata[0]: continue
    lines.append(l)
  xfile.close()
  if mnum==0:
    cmd("rm -rf '%s'" % cdir)
    return 0
  with open(infile, 'w') as xfile:
    for l in lines: xfile.write(l)
  cmd("mkdir -p '%s'" % cdir)
  with open(dfile, 'w') as xfile:
    c=-1
    for d in data:
      c+=1
      for x in d.split('\n'): xfile.write('%s:%s\n' % (c,x))
  cmd("cp -f '%s' '%s' && echo '%s' > '%s'" % (infile, efile, ncksum, sfile))
  return mnum

def do_dec(opts, infile, cdir):
  dfile = join(cdir,'config')
  if not exists(dfile):
    convert_file('-d', opts.passfile, infile, infile)
    cmd("rm -rf '%s'" % cdir)
    return 1
  with open(infile) as xfile:
    lines = xfile.readlines()
  with open(dfile) as xfile:
    data={}
    for l in xfile.readlines():
      i,d = l.split(":",1)
      if not i in data: data[i]=[]
      data[i].append(d)
  with open(infile, 'w') as xfile:
    exp =re.compile('^(.*)@JENKINS_BACKUP_([0-9]+)@(.*)')
    for l in lines:
      m = exp.match(l)
      if m:
        x = ''.join(data[m.group(2)])
        d = convert_string('-d',opts.passfile,x)
        l='%s%s%s\n' % (m.group(1),d,m.group(3))
      xfile.write(l)
  cmd("rm -rf '%s'" % cdir)
  return 1

if __name__ == "__main__":
  default_multikeys = ['privateKey']
  default_keys = ['authToken', 'passwordhash','password','apiToken', 'token','passphrase', 'proxyPassword','gitlabApiToken','slackOutgoingWebhookToken']
  default_keys += ['managerPassword', 'smtpPassword']
  from optparse import OptionParser
  parser = OptionParser(usage="%prog <infile>")
  parser.add_option("-f", dest="force",     action="store_true", help="Force encrypt.", default=False)
  parser.add_option("-d", dest="decrypt",   action="store_true", help="Decrypt the input file.", default=False)
  parser.add_option("-p", dest="partial",   action="store_true", help="Do the partial encryption/decryption. Default is full", default=False)
  parser.add_option("-k", dest="mkeywords", help="XML multi-line keywords to encrypt.", action='append', default=default_multikeys)
  parser.add_option("-K", dest="keywords",  help="XML keywords to encrypt.", action='append', default=default_keys)
  parser.add_option("-v", dest="values",    help="XML values to encrypt.", action='append', default=['^(.*<.+?>)({[^}]+})(<.+>\s*)'])
  parser.add_option("-P", dest="passfile",  help="Passfile to use to encrypt/decrypt data.", type=str, default='~/.ssh/id_dsa')
  parser.add_option("-c", dest="cache_dir", help="Jenkins backup cache directory", type=str, default='.jenkins-backup')
  opts, args = parser.parse_args()

  if len(args) == 0: parser.error("Missing input file name.")
  opts.passfile = expanduser(opts.passfile)
  if not exists (opts.passfile): parser.error("No such file: %s" % opts.passfile)
  if not exists (opts.cache_dir): cmd('mkdir -p %s' % opts.cache_dir)
  if opts.decrypt:
    opts.keywords = list(set(opts.keywords+default_keys))
    opts.mkeywords = list(set(opts.mkeywords+default_multikeys))
  process(opts, args)
