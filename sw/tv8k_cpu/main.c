// SPDX-License-Identifier: Apache-2.0
// tv8k CPU smoke program for the xuanji RV64IMAC core on the NoC. Every load
// and store goes through the core's L2 line port, the NoC and DRAM. The bench
// recomputes everything and checks the sorted copy and the signature.
#define N 64
#define A   ((volatile unsigned long *)0x80004000UL)
#define B   ((volatile unsigned long *)0x8000C000UL)
#define SIG ((volatile unsigned long *)0x80010000UL)

int main(void) {
  unsigned long sum = 0, prod = 0;
  for (unsigned long i = 0; i < N; i++) A[i] = (i * 2654435761UL) ^ (i << 7) ^ 0x5A5AUL;
  for (int i = 1; i < N; i++) {                 // insertion sort, ascending
    unsigned long x = A[i];
    int j = i - 1;
    while (j >= 0 && A[j] > x) { A[j + 1] = A[j]; j--; }
    A[j + 1] = x;
  }
  for (int i = 0; i < N; i++) {
    B[i] = A[i];
    sum += A[i];
    prod += A[i] * (unsigned long)(i + 1);
  }
  SIG[0] = sum;
  SIG[1] = prod;
  SIG[2] = sum / 12345UL;
  SIG[3] = sum % 12345UL;
  return 0;
}
