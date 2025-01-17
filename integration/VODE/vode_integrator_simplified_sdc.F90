! This is the interface to the burner for the simplified SDC case.

module vode_integrator_module

  use amrex_error_module
  use amrex_fort_module, only: rt => amrex_real
  use amrex_constants_module

  use sdc_type_module
  use vode_type_module

  use cuvode_parameters_module

  implicit none

contains

  subroutine vode_integrator_init()

  end subroutine vode_integrator_init


  subroutine vode_integrator(state_in, state_out, dt, time, status)

    use vode_rpar_indices
    use vode_rhs_module
    use cuvode_module, only: dvode
    use cuvode_types_module, only: dvode_t
    use extern_probin_module, only: jacobian, burner_verbose, &
                                    rtol_spec, rtol_temp, rtol_enuc, &
                                    atol_spec, atol_temp, atol_enuc, &
                                    retry_burn, &
                                    retry_burn_factor, retry_burn_max_change, &
                                    call_eos_in_rhs, dT_crit, use_jacobian_caching, &
                                    ode_max_steps, sdc_burn_tol_factor
    use cuvode_parameters_module
    use integration_data, only: integration_status_t

    ! Input arguments

    type (sdc_t), intent(in   ) :: state_in
    type (sdc_t), intent(inout) :: state_out
    real(rt),    intent(in   ) :: dt, time
    type (integration_status_t), intent(inout) :: status

    ! Local variables

    real(rt) :: local_time

    ! istate determines the state of the calculation.  A value of 1 meeans
    ! this is the first call to the problem -- this is what we will want.

    integer :: istate

    integer :: ipar

    real(rt) :: sum
    real(rt) :: retry_change_factor
    type (dvode_t) :: dvode_state

    logical :: integration_failed
    real(rt), parameter :: failure_tolerance = 1.e-2_rt

    real(rt) :: sdc_tol_fac, sdc_min_density

    !$gpu

    dvode_state % jacobian = jacobian

    if (use_jacobian_caching) then
       dvode_state % JSV = 1
    else
       dvode_state % JSV = -1
    endif

    ! We want VODE to re-initialize each time we call it.

    dvode_state % istate = 1

    ! Set the maximum number of steps allowed.

    dvode_state % MXSTEP = ode_max_steps

    ! Start off by assuming a successful burn.

    state_out % success = .true.
    integration_failed = .false.

    ! Initialize the integration time.

    dvode_state % T = ZERO
    dvode_state % TOUT = dt

    ! Convert our input sdc state into the form VODE expects

    call sdc_to_vode(state_in, dvode_state)

    ! Set the tolerances.  Note: we define the input atol for species
    ! to refer only to the mass fraction part, and we multiply by a
    ! representative density so that atol becomes an absolutely
    ! tolerance on (rho X)

    sdc_tol_fac = sdc_burn_tol_factor**(state_in % num_sdc_iters - state_in % sdc_iter - 1)

#if defined(SDC_EVOLVE_ENERGY)

    sdc_min_density = min(dvode_state % rpar(irp_SRHO), dvode_state % rpar(irp_SRHO) + dvode_state % rpar(irp_ydot_a-1+SRHO) * dt)

    dvode_state % atol(SFS:SFS-1+nspec) = sdc_min_density * status % atol_spec * sdc_tol_fac
    dvode_state % atol(SEDEN)           = sdc_min_density * status % atol_enuc * sdc_tol_fac
    dvode_state % atol(SEINT)           = sdc_min_density * status % atol_enuc * sdc_tol_fac

    dvode_state % rtol(SFS:SFS-1+nspec) = status % rtol_spec * sdc_tol_fac
    dvode_state % rtol(SEDEN)           = status % rtol_enuc * sdc_tol_fac
    dvode_state % rtol(SEINT)           = status % rtol_enuc * sdc_tol_fac

#elif defined(SDC_EVOLVE_ENTHALPY)

    sdc_min_density = min(dvode_state % rpar(irp_SRHO), dvode_state % rpar(irp_SRHO) + sum(dvode_state % rpar(irp_ydot_a-1+SFS:irp_ydot_a-1+SFS+nspec-1)) * dt)

    dvode_state % atol(SFS:SFS-1+nspec) = sdc_min_density * status % atol_spec * sdc_tol_fac ! mass fractions
    dvode_state % atol(SENTH)           = sdc_min_density * status % atol_enuc * sdc_tol_fac ! enthalpy

    dvode_state % rtol(SFS:SFS-1+nspec) = status % rtol_spec * sdc_tol_fac ! mass fractions
    dvode_state % rtol(SENTH)           = status % rtol_enuc * sdc_tol_fac ! enthalpy

#endif

    ! this is not used but we set it to prevent accessing uninitialzed
    ! data in common routines with the non-SDC integrator
    dvode_state % rpar(irp_self_heat) = -ONE

    ! Set the time offset -- this converts between the local integration
    ! time and the simulation time
    dvode_state % rpar(irp_t0) = time


    ! Call the integration routine.
    call dvode(dvode_state)

    ! Store the final data
    call vode_to_sdc(dvode_state % T, dvode_state, state_out)

    ! VODE does not always fail even though it can lead to unphysical states,
    ! so add some sanity checks that trigger a retry even if VODE thinks
    ! the integration was successful.

    if (dvode_state % istate < 0) then
       integration_failed = .true.
    end if

#if defined(SDC_EVOLVE_ENERGY)
    if (dvode_state % y(SEINT) < ZERO .or. dvode_state % y(SEDEN) < ZERO) then
       integration_failed = .true.
    end if

    if (any(dvode_state % y(SFS:SFS+nspec-1) / state_out % y(SRHO) < -failure_tolerance)) then
       integration_failed = .true.
    end if

    if (any(dvode_state % y(SFS:SFS+nspec-1) / state_out % y(SRHO) > 1.e0_rt + failure_tolerance)) then
       integration_failed = .true.
    end if
#elif defined(SDC_EVOLVE_ENTHALPY)
    if (any(dvode_state % y(SFS:SFS+nspec-1) / state_out % rho < -failure_tolerance)) then
       integration_failed = .true.
    end if

    if (any(dvode_state % y(SFS:SFS+nspec-1) / state_out % rho > 1.e0_rt + failure_tolerance)) then
       integration_failed = .true.
    end if
#endif

    ! If we failed, print out the current state of the integration.

    if (integration_failed) then
#ifndef CUDA
#if defined(SDC_EVOLVE_ENERGY)
       print *, 'ERROR: integration failed in net'
       print *, 'istate = ', dvode_state % istate
       print *, 'time = ', dvode_state % T
       print *, 'dens start = ', state_in % y(SRHO)
       print *, 'eint start = ', state_in % y(SEINT) / state_in % y(SRHO)
       print *, 'xn start = ', state_in % y(SFS:SFS+nspec-1) / state_in % y(SRHO)
       print *, 'dens current = ', state_out % y(SRHO)
       print *, 'eint current = ', state_out % y(SEINT) / state_out % y(SRHO)
       print *, 'xn current = ', state_out % y(SFS:SFS+nspec-1) / state_out % y(SRHO)
       print *, 'energy generated = ', state_out % y(SEDEN) / state_out % y(SRHO) - &
            state_in % y(SEDEN) / state_in % y(SRHO)
#endif
#endif

       state_out % success = .false.
       return
    endif

    ! get the number of RHS calls and jac evaluations from the VODE
    ! work arrays
    state_out % n_rhs = dvode_state % NFE
    state_out % n_jac = dvode_state % NJE

  end subroutine vode_integrator

end module vode_integrator_module
