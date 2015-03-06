use BlockDist;
use GMP;

config const n = 20;
const Space = {1..n};
const D = Space dmapped Block(boundingBox=Space);

var A: [D] BigInt;
var B: [D] BigInt;
var C: [D] BigInt;
var E: [D] BigInt;
var F: [D] BigInt;

// Fill the arrays with something easy.
forall (x,i) in zip(A,D) {
  x = new BigInt(1);
  //x = i;
}
forall (x,i) in zip(B,D) {
  x = new BigInt(2);
  //x = i;
}

writeln(A);
writeln(B);

forall (x,i) in zip(C,D) {
  x = new BigInt(i);
  x.fac_ui((10*i):uint(32));
  //x = i;
}

writeln("factorials:");
for (c,i) in zip(C,D) {
  writeln(i, " ", c);
  c.debugprint();
}

assert(C[1].get_str()=="3628800");
assert(C[2].get_str()=="2432902008176640000");
assert(C[3].get_str()=="265252859812191058636308480000000");
assert(C[4].get_str()=="815915283247897734345611269596115894272000000000");
assert(C[5].get_str()=="30414093201713378043612608166064768844377641568960512000000000000");
assert(C[6].get_str()=="8320987112741390144276341183223364380754172606361245952449277696409600000000000000");
assert(C[10].get_str()=="93326215443944152681699238856266700490715968264381621468592963895217599993229915608941463976156518286253697920827223758251185210916864000000000000000000000000");
assert(C[20].get_str()=="788657867364790503552363213932185062295135977687173263294742533244359449963403342920304284011984623904177212138919638830257642790242637105061926624952829931113462857270763317237396988943922445621451664240254033291864131227428294853277524242407573903240321257405579568660226031904170324062351700858796178922222789623703897374720000000000000000000000000000000000000000000000000");

forall (a,b,c) in zip(A,B,C) {
  c.add(c,a);
  c.add(c,b);
  //c = a + b;
  c.debugprint();
}

writeln("factorials after adds:");
for (c,i) in zip(C,D) {
  writeln(i, " ", c);
  c.debugprint();
}

writeln("checking");
assert(C[1].get_str()=="3628803");
assert(C[2].get_str()=="2432902008176640003");
assert(C[3].get_str()=="265252859812191058636308480000003");
assert(C[4].get_str()=="815915283247897734345611269596115894272000000003");
assert(C[5].get_str()=="30414093201713378043612608166064768844377641568960512000000000003");
assert(C[6].get_str()=="8320987112741390144276341183223364380754172606361245952449277696409600000000000003");

forall (x,i) in zip(E,D) {
  x = new BigInt(3);
  //x = i;
}

forall (a,b,c) in zip(A,B,E) {
  c.add(c,a);
  c.add(c,b);
  //c = a + b;
}
//writeln(C);

var sum = new BigInt(0);
for c in E {
  //writeln(c.locale, " ", c.sizeinbase(10));
  //writeln(c.sizeinbase(10));
  sum.add(sum, c);
}

writeln("next value should be ", n*6);
writeln(sum);

writeln("sum size of factorials");

C[1].debugprint();

sum.set(0);
for (c,i) in zip(C,D) {
  //writeln(c.locale, " ", c.sizeinbase(10));
  //writeln(c.sizeinbase(10));
  sum.add(sum, c);
  c.debugprint();
  F[i] = sum;
  writeln(sum);
}

writeln(sum.sizeinbase(10));
writeln(sum);
assert(sum.get_str()=="788657867364790503552372894254860317544292101234583941125082251062578507150846240696731966115159319935141037002072184790958428488679627607110845462800339568363449772395171945193605925593057514393227079618757671532928290719047905235400839693113116674212936444454607656470693851389958498644630731961682899037537010467603069195487349113279207554182411410772454657544588660268860");

var modulus = new BigInt("10000000000000000000000000000000000000000");
modulus.nextprime(modulus);
writeln(modulus);
sum.mod(sum, modulus);
writeln(sum);
