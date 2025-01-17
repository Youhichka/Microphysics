module vode_type_module

  use cuvode_types_module, only : dvode_t
  use cuvode_parameters_module, only: VODE_NEQS
  use amrex_fort_module, only: rt => amrex_real

  implicit none

contains
  
  subroutine clean_state(vode_state)

    !$acc routine seq

    use amrex_constants_module, only: ONE
    use actual_network, only: nspec
    use burn_type_module, only: neqs, net_itemp
    use vode_rpar_indices, only: n_rpar_comps
    use eos_type_module, only : eos_get_small_temp
    use extern_probin_module, only: renormalize_abundances, SMALL_X_SAFE, MAX_TEMP

    implicit none

    type(dvode_t), intent(inout) :: vode_state

    real(rt) :: small_temp

    !$gpu

    ! Ensure that mass fractions always stay positive and less than or equal to 1.

    vode_state % y(1:nspec) = max(min(vode_state % y(1:nspec), ONE), SMALL_X_SAFE)

    ! Renormalize the abundances as necessary.

    if (renormalize_abundances) then
       call renormalize_species(vode_state)
    endif

    ! Ensure that the temperature always stays within reasonable limits.

    call eos_get_small_temp(small_temp)

    vode_state % y(net_itemp) = &
         min(MAX_TEMP, max(vode_state % y(net_itemp), small_temp))

  end subroutine clean_state


  subroutine renormalize_species(vode_state)

    !$acc routine seq
    
    use network, only: nspec
    use burn_type_module, only: neqs
    use vode_rpar_indices, only: n_rpar_comps

    implicit none

    type(dvode_t), intent(inout) :: vode_state

    real(rt) :: nspec_sum

    !$gpu

    nspec_sum = sum(vode_state % y(1:nspec))
    vode_state % y(1:nspec) = vode_state % y(1:nspec) / nspec_sum

  end subroutine renormalize_species


  subroutine update_thermodynamics(vode_state)

    !$acc routine seq

    use amrex_constants_module, only: ZERO
    use extern_probin_module, only: call_eos_in_rhs, dT_crit
    use eos_type_module, only: eos_t, eos_input_rt
    use eos_composition_module, only : composition
    use eos_module, only: eos
    use vode_rpar_indices, only: n_rpar_comps, irp_self_heat, irp_cp, irp_cv, irp_Told, &
                                 irp_dcpdt, irp_dcvdt, irp_abar, irp_ye, irp_zbar
    use burn_type_module, only: neqs
    use network, only : nspec, aion_inv, zion

    implicit none

    type (dvode_t), intent(inout) :: vode_state

    type (eos_t) :: eos_state
    real ::mu_e

    !$gpu
    
    ! Several thermodynamic quantities come in via rpar -- note: these
    ! are evaluated at the start of the integration, so if things change
    ! dramatically, they will fall out of sync with the current
    ! thermodynamics.
    
#ifdef NSE_THERMO
    ! we are handling the thermodynamics via the aux quantities, which
    ! are stored in the rpar here, so we need to update those based on
    ! the current state.

    vode_state % rpar(irp_abar) = 1.0_rt / (sum(vode_state % y(1:nspec) * aion_inv(:)))
    mu_e = 1.0_rt / sum(vode_state % y(1:nspec) * zion(:) * aion_inv(:))
    vode_state % rpar(irp_ye) = 1.0_rt / mu_e
    vode_state % rpar(irp_zbar) = vode_state % rpar(irp_abar) * vode_state % rpar(irp_ye)

#endif

    call vode_to_eos(eos_state, vode_state)

    ! Evaluate the thermodynamics -- if desired. Note that
    ! even if this option is selected, we don't need to do it
    ! for non-self-heating integrations because the temperature
    ! isn't being updated. Also, if it is, we can optionally
    ! set a fraction dT_crit such that we don't call the EOS
    ! if the last temperature we evaluated the EOS at is relatively
    ! close to the current temperature.

    ! Otherwise just do the composition calculations since
    ! that's needed to construct dY/dt. Then make sure
    ! the abundances are safe.

    if (call_eos_in_rhs .and. vode_state % rpar(irp_self_heat) > ZERO) then

       call eos(eos_input_rt, eos_state)

    else if (abs(eos_state % T - vode_state % rpar(irp_Told)) > dT_crit * eos_state % T .and. &
             vode_state % rpar(irp_self_heat) > ZERO) then

       call eos(eos_input_rt, eos_state)

       vode_state % rpar(irp_dcvdt) = (eos_state % cv - vode_state % rpar(irp_cv)) / &
            (eos_state % T - vode_state % rpar(irp_Told))
       vode_state % rpar(irp_dcpdt) = (eos_state % cp - vode_state % rpar(irp_cp)) / &
            (eos_state % T - vode_state % rpar(irp_Told))
       vode_state % rpar(irp_Told)  = eos_state % T

       ! note: the update to rpar(irp_cv) and irp_cp is done
       ! in the call to eos_to_bs that follows this block.

    else

       call composition(eos_state)

    endif

    call eos_to_vode(eos_state, vode_state)

  end subroutine update_thermodynamics



  ! Given an rpar array and the integration state, set up an EOS state.
  ! We could fill the energy component by storing the initial energy in
  ! rpar if we wanted, but we won't do that because (1) if we do call the EOS,
  ! it is always in (rho, T) mode and (2) converting back would imply subtracting
  ! off the nuclear energy from the zone's internal energy, which could lead to
  ! issues from roundoff error if the energy released from burning is small.

  subroutine vode_to_eos(state, vode_state)

    !$acc routine seq

    use integrator_scaling_module, only: dens_scale, temp_scale
    use network, only: nspec
#ifdef NSE_THERMO
    use network, only: iye, iabar, ibea
#endif
    use eos_type_module, only: eos_t
    use vode_rpar_indices, only: irp_dens, irp_cp, irp_cv, irp_abar, irp_zbar, &
                            irp_eta, irp_ye, n_rpar_comps
    use burn_type_module, only: neqs, net_itemp

    implicit none

    type (eos_t) :: state
    type (dvode_t), intent(in) :: vode_state

    !$gpu

    state % rho     = vode_state % rpar(irp_dens) * dens_scale
    state % T       = vode_state % y(net_itemp) * temp_scale

    state % xn(1:nspec) = vode_state % y(1:nspec)

#ifdef NSE_THERMO
    state % aux(iye) = vode_state % rpar(irp_ye)
    state % aux(iabar) = vode_state % rpar(irp_abar)
    state % aux(ibea) = 0.0_rt
#endif

    state % cp      = vode_state % rpar(irp_cp)
    state % cv      = vode_state % rpar(irp_cv)
    state % abar    = vode_state % rpar(irp_abar)
    state % zbar    = vode_state % rpar(irp_zbar)
    state % eta     = vode_state % rpar(irp_eta)
    state % y_e     = vode_state % rpar(irp_ye)

  end subroutine vode_to_eos



  ! Given an EOS state, fill the rpar and integration state data.

  subroutine eos_to_vode(state, vode_state)

    !$acc routine seq

    use integrator_scaling_module, only: inv_dens_scale, inv_temp_scale
    use network, only: nspec
#ifdef NSE_THERMO
    use network, only: iabar, iye
#endif
    use eos_type_module, only: eos_t
    use vode_rpar_indices, only: irp_dens, irp_cp, irp_cv, irp_abar, irp_zbar, &
                            irp_eta, irp_ye, n_rpar_comps
    use burn_type_module, only: neqs, net_itemp

    implicit none

    type (eos_t), intent(in) :: state
    type(dvode_t), intent(inout) :: vode_state

    !$gpu

    vode_state % rpar(irp_dens) = state % rho * inv_dens_scale
    vode_state % y(net_itemp) = state % T * inv_temp_scale

    vode_state % y(1:nspec) = state % xn(1:nspec)

#ifdef NSE_THERMO
    vode_state % rpar(irp_ye) = state % aux(iye)
    vode_state % rpar(irp_abar) = state % aux(iabar)
#endif

    vode_state % rpar(irp_cp) = state % cp
    vode_state % rpar(irp_cv) = state % cv
    vode_state % rpar(irp_abar) = state % abar
    vode_state % rpar(irp_zbar) = state % zbar
    vode_state % rpar(irp_eta) = state % eta
    vode_state % rpar(irp_ye) = state % y_e

  end subroutine eos_to_vode


  ! Given a burn state, fill the rpar and integration state data.

  subroutine burn_to_vode(state, vode_state)

    !$acc routine seq

    use integrator_scaling_module, only: inv_dens_scale, inv_temp_scale, inv_ener_scale
    use amrex_constants_module, only: ONE
    use network, only: nspec
#ifdef NSE_THERMO
    use network, only: iabar, iye
#endif
    use vode_rpar_indices, only: irp_dens, irp_cp, irp_cv, irp_abar, irp_zbar, &
                            irp_ye, irp_eta, &
                            irp_Told, irp_dcvdt, irp_dcpdt, irp_self_heat, &
                            n_rpar_comps
    use burn_type_module, only: neqs, burn_t, net_itemp, net_ienuc

    implicit none

    type (burn_t), intent(in) :: state
    type (dvode_t), intent(inout) :: vode_state

    !$gpu

    vode_state % rpar(irp_dens) = state % rho * inv_dens_scale
    vode_state % y(net_itemp) = state % T * inv_temp_scale
    vode_state % y(net_ienuc) = state % e * inv_ener_scale

#ifdef NSE_THERMO
    vode_state % rpar(irp_ye) = state % aux(iye)
    vode_state % rpar(irp_abar) = state % aux(iabar)
#endif


  end subroutine burn_to_vode


  ! Given an rpar array and the integration state, set up a burn state.

  subroutine vode_to_burn(vode_state, state)

    !$acc routine seq

    use integrator_scaling_module, only: dens_scale, temp_scale, ener_scale
    use amrex_constants_module, only: ZERO
    use network, only: nspec
#ifdef NSE_THERMO
    use network, only: iye, iabar
#endif
    use vode_rpar_indices, only: irp_dens, irp_cp, irp_cv, irp_abar, irp_zbar, &
                            irp_ye, irp_eta, &
                            irp_Told, irp_dcvdt, irp_dcpdt, irp_self_heat, &
                            n_rpar_comps
    use burn_type_module, only: neqs, burn_t, net_itemp, net_ienuc

    implicit none

    type (burn_t), intent(inout) :: state
    type (dvode_t), intent(in) :: vode_state

    !$gpu

    state % rho      = vode_state % rpar(irp_dens) * dens_scale
    state % T        = vode_state % y(net_itemp) * temp_scale
    state % e        = vode_state % y(net_ienuc) * ener_scale

    state % xn(1:nspec) = vode_state % y(1:nspec)

#ifdef NSE_THERMO
    state % aux(iye) = vode_state % rpar(irp_ye)
    state % aux(iabar) = vode_state % rpar(irp_abar)
#endif

    state % cp       = vode_state % rpar(irp_cp)
    state % cv       = vode_state % rpar(irp_cv)
    state % abar     = vode_state % rpar(irp_abar)
    state % zbar     = vode_state % rpar(irp_zbar)
    state % y_e      = vode_state % rpar(irp_ye)
    state % eta      = vode_state % rpar(irp_eta)

    state % T_old    = vode_state % rpar(irp_Told)
    state % dcvdt    = vode_state % rpar(irp_dcvdt)
    state % dcpdt    = vode_state % rpar(irp_dcpdt)

    if (vode_state % rpar(irp_self_heat) > ZERO) then
       state % self_heat = .true.
    else
       state % self_heat = .false.
    endif

  end subroutine vode_to_burn

end module vode_type_module
