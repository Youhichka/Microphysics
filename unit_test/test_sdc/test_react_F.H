#ifndef TEST_EOS_F_H_
#define TEST_EOS_F_H_

#include <AMReX_BLFort.H>

#ifdef __cplusplus
#include <AMReX.H>
extern "C"
{
#endif
  void init_variables_F();

  void init_unit_test(const int* name, const int* namlen);

  void do_react_F(const int* lo, const int* hi,
                amrex::Real* state, const int* s_lo, const int* s_hi,
                int* n_rhs, const int* n_rhs_lo, const int* n_rhs_hi);

#ifdef __cplusplus
}
#endif

#endif
