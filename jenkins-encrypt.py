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
  odir = dirname(outfile)
  if odir: cmd("mkdir -p '%s'" % odir)
  cmd("openssl enc %s -md sha256 -a -base64 -aes-256-cbc -salt -in '%s' -out '%s.tmp' -pass file:%s" % (xtype, infile, outfile, passfile))
  cmd ("mv '%s.tmp' '%s'" % (outfile, outfile))
  return True

def process(opts, infiles):
  if not opts.decrypt:
    search = []
    for v in opts.values:   search.append(re.compile(v, re.I))
    for k in opts.keywords: search.append(re.compile('^(\s*<%s>)([^<]+)(</%s>\s*)' % (k,k),re.I))
    opts.keywords = search
  cwd = abspath(getcwd())+"/"
  for infile in [abspath(f) for f in infiles]:
    if not infile.startswith(cwd):
      print "ERROR: Invalid file, not available in current working directory: ",infile
      sys.exit(1)
    infile = infile.replace(cwd, "")
    cdir = '%s/%s' % (opts.cache_dir, infile.split("/",1)[-1] if opts.decrypt else infile)
    res = 0
    if opts.decrypt: res = do_dec(opts, infile, cdir)
    else:            res = do_enc(opts, infile, cdir)
    if res!=0:
      if res>0: print "Processed ",res,infile
      cmd("rm -rf '%s'" % infile)

def do_enc(opts, infile, cdir):
  efile = join(cdir,'contents')
  sfile = join(cdir,'cksum')
  dfile = join(cdir,'data')
  ncksum = cmd("sha256sum -b '%s' | sed 's| .*||'" % infile).strip('\n')
  if not opts.force and exists(sfile):
    ocksum = open(sfile).readline().strip('\n')
    if (ncksum==ocksum) and exists(efile): return -1
  cmd("rm -rf '%s'" % cdir)
  if not opts.partial:
    convert_file('-e', opts.passfile, infile, efile)
    cmd("echo '%s' > '%s'" % (ncksum, sfile))
    return 1
  mnum=0
  data=[]
  lines = []
  xfile = open(infile)
  for l in xfile.readlines():
    for exp in opts.keywords:
      m = exp.match(l)
      if m:
         x=[]
         data.append(convert_string('-e',opts.passfile, m.group(2)))
         l='%s@JENKINS_BACKUP_%s@%s' % (m.group(1),mnum,m.group(3))
         mnum+=1
         break
    lines.append(l)
  xfile.close()
  if mnum:
    cmd("mkdir -p '%s'" % cdir)
    xfile = open(efile, 'w')
    for l in lines: xfile.write(l)
    xfile.close()
    xfile=open(dfile, 'w')
    c=-1
    for d in data:
      c+=1
      for x in d.split('\n'): xfile.write('%s:%s\n' % (c,x))
    xfile.close()
    cmd("echo '%s' > '%s'" % (ncksum, sfile))
  return mnum

def do_dec(opts, infile, cdir):
  infile = dirname(infile) if infile.endswith('/contents') else infile
  efile  = infile.split("/",1)[-1]
  infile = join(cdir,'contents')
  dfile = join(cdir,'data')
  if not exists(dfile):
    convert_file('-d', opts.passfile, infile, efile)
    return 1
  xfile = open(infile)
  lines = xfile.readlines()
  xfile.close()
  xfile = open(dfile)
  data={}
  for l in xfile.readlines():
    i,d = l.split(":",1)
    if not i in data: data[i]=[]
    data[i].append(d)
  xfile.close()
  edir = dirname(efile)
  if edir: cmd("mkdir -p '%s'" % edir)
  xfile = open(efile, 'w')
  exp =re.compile('^(.*)@JENKINS_BACKUP_([0-9]+)@(.*)')
  for l in lines:
    m = exp.match(l)
    if m:
      x = ''.join(data[m.group(2)])
      d = convert_string('-d',opts.passfile,x)
      l='%s%s%s\n' % (m.group(1),d,m.group(3))
    xfile.write(l)
  xfile.close()
  return 1

if __name__ == "__main__":
  from optparse import OptionParser
  parser = OptionParser(usage="%prog <infile>")
  parser.add_option("-f", dest="force",   action="store_true", help="Force encrypt.", default=False)
  parser.add_option("-d", dest="decrypt",   action="store_true", help="Decrypt the input file.", default=False)
  parser.add_option("-p", dest="partial",   action="store_true", help="Do the partial encryption/decryption. Default is full", default=False)
  parser.add_option("-k", dest="keywords",  help="XML keywords to encrypt.", action='append', default=['passwordhash','password','apiToken', 'token'])
  parser.add_option("-v", dest="values",    help="XML values to encrypt.", action='append', default=['^(.*<.+?>)({[^}]+})(<.+>\s*)'])
  parser.add_option("-P", dest="passfile",  help="Passfile to use to encrypt/decrypt data.", type=str, default='~/.ssh/id_dsa')
  parser.add_option("-c", dest="cache_dir", help="Jenkins backup cache directory", type=str, default='.jenkins-backup')
  opts, args = parser.parse_args()

  if len(args) == 0: parser.error("Missing input file name.")
  opts.passfile = expanduser(opts.passfile)
  if not exists (opts.passfile): parser.error("No such file: %s" % opts.passfile)
  if not exists (opts.cache_dir): cmd('mkdir -p %s' % opts.cache_dir)
  process(opts, args)
