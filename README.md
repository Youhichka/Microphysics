# Microphysics

*A collection of astrophysical microphysics routines with interfaces to
 the BoxLib codes*

To use this repository with BoxLib codes, set `MICROPHYSICS_DIR` to point
to the `Microphysics/` directory.

There are several core types of microphysics routines hosted here:

* `aprox_rates/`: this contains some common rate routines used by the
  various `aprox` networks
  
* `eos/`: these are the equations of state.  All of them use a Fortran
  derived type `eos_t` to pass the thermodynamic state information in
  and out.

* `integration/`: this holds the various ODE integrators.  Some have
  been marked up with OpenACC to run on GPUs

* `interfaces/`: this holds the Fortran derived types used to
  interface with the EOS and networks.  Note: copies of these are
  included with Maestro and Castro.  They are copied here for testing
  and to enable other codes to use this repo.

* `networks/`: these are the reaction networks.  They serve both to
  define the composition and its properties, as well as describe the
  reactions and energy release when reactions occur.

* `neutrinos/`: this holds the plasma neutrino cooling routines used
  in the reaction networks.
  
* `NSE/`:

* `screening/`: the screening routines for nuclear reactions.  These
  are called by the various networks
  
* `unit_test/`: code specific to unit tests within this repo

* `util`: linear algebra routines for the various integrators (including
  BLAS and LINPACK)


These routines are written to be compatible with:

* Castro: http://boxlib-codes.github.io/Castro/

* Maestro: http://boxlib-codes.github.io/MAESTRO/


