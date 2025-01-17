module react_zones_module

  use variables
  use network
  use eos_type_module
  use eos_module
  use sdc_type_module
  use amrex_fort_module, only : rt => amrex_real
  use amrex_constants_module
  use extern_probin_module
  use integrator_module, only: integrator

  implicit none

contains

  subroutine do_react_F(lo, hi, &
                        state, s_lo, s_hi, &
                        n_rhs, n_rhs_lo, n_rhs_hi) bind(C, name="do_react_F")

    implicit none

    integer, intent(in) :: lo(3), hi(3)
    integer, intent(in) :: s_lo(3), s_hi(3)
    integer, intent(in) :: n_rhs_lo(3), n_rhs_hi(3)
    real(rt), intent(inout) :: state(s_lo(1):s_hi(1), s_lo(2):s_hi(2), s_lo(3):s_hi(3), p % n_plot_comps)
    integer,  intent(inout) :: n_rhs(n_rhs_lo(1):n_rhs_hi(1), n_rhs_lo(2):n_rhs_hi(2), n_rhs_lo(3):n_rhs_hi(3), 1)

    type (eos_t) :: eos_state
    type (sdc_t)   :: sdc_state_in, sdc_state_out
    integer         :: ii, jj, kk, j
    real(rt) :: sum_spec

    do kk = lo(3), hi(3)
       do jj = lo(2), hi(2)
          do ii = lo(1), hi(1)

             ! populate the SDC state.  Our strategy for the unit test is to choose
             ! the advective terms to all be zero and to choose the velocity to be
             ! Mach = 0.1

             ! call the EOS first to get the sound speed
             eos_state % rho = state(ii, jj, kk, p % irho)
             eos_state % T = state(ii, jj, kk, p % itemp)
             eos_state % xn(:) = state(ii, jj, kk, p % ispec_old:p % ispec_old-1+nspec)

             call eos(eos_input_rt, eos_state)

#if defined(SDC_EVOLVE_ENERGY)
             sdc_state_in % y(SRHO) = state(ii, jj, kk, p % irho)

             ! we will pick velocities to be 10% of the sound speed
             sdc_state_in % y(SMX:SMZ) = sdc_state_in % y(SRHO) * 0.1_rt * eos_state % cs

             sdc_state_in % y(SEINT) = sdc_state_in % y(SRHO) * eos_state % e
             sdc_state_in % y(SEDEN) = sdc_state_in % y(SEINT) + &
                  HALF*sum(sdc_state_in % y(SMX:SMZ)**2)/sdc_state_in % y(SRHO)
             sdc_state_in % y(SFS:SFS-1+nspec) = sdc_state_in % y(SRHO) * eos_state % xn(:)

             ! normalize
             sum_spec = sum(sdc_state_in % y(SFS:SFS-1+nspec))/ sdc_state_in % y(SRHO)
             sdc_state_in % y(SFS:SFS-1+nspec) = sdc_state_in % y(SFS:SFS-1+nspec)/sum_spec

             ! need to set this consistently
             sdc_state_in % T_from_eden = .true.

#elif defined(SDC_EVOLVE_ENTHALPY)
             sdc_state_in % y(SRHO) = state(ii, jj, kk, p % irho)

             sdc_state_in % y(SENTH) = sdc_state_in % y(SRHO) * eos_state % e + eos_state % p
             sdc_state_in % y(SFS:SFS-1+nspec) = sdc_state_in % y(SRHO) * eos_state % xn(:)

             ! normalize
             sum_spec = sum(sdc_state_in % y(SFS:SFS-1+nspec))/ sdc_state_in % y(SRHO)
             sdc_state_in % y(SFS:SFS-1+nspec) = sdc_state_in % y(SFS:SFS-1+nspec)/sum_spec

             sdc_state_in % p0 = eos_state % p
             sdc_state_in % rho = eos_state % rho
#endif

             ! zero out the advective terms
             sdc_state_in % ydot_a(:) = ZERO

             ! need to set T_from_eden

             call integrator(sdc_state_in, sdc_state_out, tmax, ZERO)

             do j = 1, nspec
                state(ii, jj, kk, p % ispec+j-1) = sdc_state_out % y(SFS+j-1)/sdc_state_out % y(SRHO)
             enddo

             do j=1, nspec
                ! an explicit loop is needed here to keep the GPU happy
                state(ii, jj, kk, p % irodot + j - 1) = &
                     (sdc_state_out % y(SFS+j-1) - sdc_state_in % y(SFS+j-1)) / tmax
             enddo

#if defined(SDC_EVOLVE_ENERGY)
             state(ii, jj, kk, p % irho_hnuc) = &
                  (sdc_state_out % y(SEINT) - sdc_state_in % y(SEINT)) / tmax

#elif defined(SDC_EVOLVE_ENTHALPY)
             state(ii, jj, kk, p % irho_hnuc) = &
                  (sdc_state_out % y(SENTH) - sdc_state_in % y(SENTH)) / tmax
#endif

             n_rhs(ii, jj, kk, 1) = sdc_state_out % n_rhs

          enddo
       enddo
    enddo

  end subroutine do_react_F

end module react_zones_module
