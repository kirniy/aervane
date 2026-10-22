#include "../Sources/SMC/include/SMC.h"
#include <stdio.h>
int main(void){const char*ks[]={"F0Md","F0Tg","F0Sf","F0St","F0Mn","F0Mx","F0Ac","F0ID","F0Er"};zsmc_open();for(int i=0;i<9;i++){unsigned char b[32];size_t n=0;uint32_t t=0;int r=zsmc_read_key_name(ks[i],b,32,&n,&t);printf("%s rc=%d type=%08x n=%zu ",ks[i],r,t,n);for(size_t j=0;j<n;j++)printf("%02x",b[j]);puts("");}zsmc_close();}
