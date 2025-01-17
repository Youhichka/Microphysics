module cuvode_module

  use cuvode_parameters_module, only: VODE_NEQS
  use cuvode_types_module, only: dvode_t, UROUND
  use vode_rpar_indices
  use amrex_fort_module, only: rt => amrex_real
  use linpack_module
  use cuvode_dvhin_module
  use cuvode_dvstep_module
  
  implicit none

  public :: dvode
  
contains

  subroutine dvode(vstate)

    !$acc routine seq

#ifdef TRUE_SDC
    use sdc_vode_rhs_module, only: f_rhs, jac
#else
    use vode_rhs_module, only: f_rhs, jac
#endif

    implicit none

    ! Declare arguments
    type(dvode_t), intent(inout) :: vstate

    ! Declare local variables
    real(rt) :: H0, S
    real(rt) :: TOLSF
    integer    :: i, j, jb, IER
    integer    :: NITER
    integer    :: NSLAST
    integer    :: pivot(VODE_NEQS)

    ! Parameter declarations
    integer, parameter :: MXSTP0 = 500
    integer, parameter :: MXHNL0 = 10

    logical :: skip_loop_start

    !$gpu

    if (vstate % TOUT .EQ. vstate % T) RETURN

    H0 = 0.0_rt

    ! -----------------------------------------------------------------------
    !  All remaining initializations, the initial call to F,
    !  and the calculation of the initial step size.
    !  The error weights in EWT are inverted after being loaded.
    ! -----------------------------------------------------------------------

    vstate % TN = vstate % T

    vstate % JSTART = 0
    vstate % NST = 0
    vstate % NJE = 0
    vstate % NSLJ = 0
    NSLAST = 0
    vstate % HU = 0.0_rt

    ! Initial call to F.  -------------------------

    call f_rhs (vstate % T, vstate, vstate % yh(:,2))
    vstate % NFE = 1
    ! Load the initial value array in YH. ---------------------------------
    vstate % YH(1:VODE_NEQS,1) = vstate % Y(1:VODE_NEQS)

    ! Load and invert the EWT array.  (H is temporarily set to 1.0.) -------
    vstate % NQ = 1
    vstate % H = 1.0_rt

    do I = 1,VODE_NEQS
       vstate % ewt(I) = vstate % RTOL(I) * abs(vstate % YH(I,1)) + vstate % ATOL(I)
       vstate % ewt(I) = 1.0_rt / vstate % ewt(I)
    end do

    ! Call DVHIN to set initial step size H0 to be attempted. --------------
    call DVHIN (vstate, H0, NITER, IER)
    vstate % NFE = vstate % NFE + NITER

    if (IER /= 0) then
#ifndef AMREX_USE_GPU
       print *, "DVODE: TOUT too close to T to start integration"
#endif
       vstate % ISTATE = -3
       return
    end if

    ! Load H with H0 and scale YH(*,2) by H0. ------------------------------
    vstate % H = H0
    vstate % YH(:,2) = vstate % YH(:,2) * H0

    skip_loop_start = .true.

    ! -----------------------------------------------------------------------
    !  Block E.
    !  The next block is normally executed for all calls and contains
    !  the call to the one-step core integrator DVSTEP.
    !
    !  This is a looping point for the integration steps.
    !
    !  First check for too many steps being taken, update EWT (if not at
    !  start of problem), check for too much accuracy being requested, and
    !  check for H below the roundoff level in T.
    ! -----------------------------------------------------------------------

    do while (.true.)

       if (.not. skip_loop_start) then

          if ((vstate % NST-NSLAST) >= vstate % MXSTEP) then
             ! The maximum number of steps was taken before reaching TOUT. ----------
#ifndef AMREX_USE_GPU
             print *, "DVODE: maximum number of steps taken before reaching TOUT"
#endif
             vstate % ISTATE = -1

             vstate % Y(1:VODE_NEQS) = vstate % YH(1:VODE_NEQS,1)

             vstate % T = vstate % TN

             return

          end if

          do I = 1,VODE_NEQS
             vstate % ewt(I) = vstate % RTOL(I) * abs(vstate % YH(I,1)) + vstate % ATOL(I)
             vstate % ewt(I) = 1.0_rt/vstate % ewt(I)
          end do

       else
          skip_loop_start = .false.
       end if

       TOLSF = UROUND * sqrt(sum((vstate % YH(:,1) * vstate % EWT(:))**2) / VODE_NEQS)

       if (TOLSF > 1.0_rt) then
          TOLSF = TOLSF*2.0_rt

          if (vstate % NST .EQ. 0) then
#ifndef AMREX_USE_GPU
             print *, "DVODE: too much accuracy requested at start of integration"
#endif
             vstate % ISTATE = -3
             return
          end if

          ! Too much accuracy requested for machine precision. -------------------
#ifndef AMREX_USE_GPU
          print *, "DVODE: too much accuracy requested"
#endif
          vstate % ISTATE = -2

          vstate % Y(1:VODE_NEQS) = vstate % YH(1:VODE_NEQS,1)

          vstate % T = vstate % TN

          return

       end if

       call dvstep(pivot, vstate)

       ! Branch on KFLAG.  Note: In this version, KFLAG can not be set to -3.
       !  KFLAG .eq. 0,   -1,  -2

       if (vstate % kflag == -1) then
          ! KFLAG = -1.  Error test failed repeatedly or with ABS(H) = HMIN. -----
#ifndef AMREX_USE_GPU
          print *, "DVODE: error test failed repeatedly or with abs(H) = HMIN"
#endif
          vstate % ISTATE = -4

          ! Set Y array, T, and optional output. --------------------------------
          vstate % Y(1:VODE_NEQS) = vstate % YH(1:VODE_NEQS,1)

          vstate % T = vstate % TN

          return

       else if (vstate % kflag == -2) then
          ! KFLAG = -2.  Convergence failed repeatedly or with ABS(H) = HMIN. ----
#ifndef AMREX_USE_GPU
          print *, "DVODE: corrector convergence failed repeatedly or with abs(H) = HMIN"
#endif
          vstate % ISTATE = -5

          ! Set Y array, T, and optional output. --------------------------------
          vstate % Y(1:VODE_NEQS) = vstate % YH(1:VODE_NEQS,1)

          vstate % T = vstate % TN

          return
       end if

       ! -----------------------------------------------------------------------
       !  Block F.
       !  The following block handles the case of a successful return from the
       !  core integrator (KFLAG = 0).  Test for stop conditions.
       ! -----------------------------------------------------------------------

       if ((vstate % TN - vstate % TOUT) * vstate % H .LT. 0.0_rt) cycle

       ! If TOUT has been reached, interpolate. -------------------

       do i = 1, VODE_NEQS
          vstate % Y(i) = vstate % YH(i,vstate % L)
       end do

       S = (vstate % TOUT - vstate % TN) / vstate % H

       do jb = 1, vstate % NQ
          j = vstate % NQ - jb
          do i = 1, VODE_NEQS
             vstate % Y(i) = vstate % YH(i,j+1) + S * vstate % Y(i)
          end do
       end do

       vstate % T = vstate % TOUT

       vstate % ISTATE = 2

       return

    end do

    ! -----------------------------------------------------------------------
    !  Block G.
    !  The following block handles all successful returns from DVODE.
    !  vstate % ISTATE is set to 2, and the optional output is loaded into the work
    !  arrays before returning.
    ! -----------------------------------------------------------------------

    vstate % Y(1:VODE_NEQS) = vstate % YH(1:VODE_NEQS,1)

    vstate % T = vstate % TN

    vstate % ISTATE = 2

    return

  end subroutine dvode
      
end module cuvode_module
