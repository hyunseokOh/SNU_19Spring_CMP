! ---
! Copyright (C) 1996-2016	The SIESTA group
!  This file is distributed under the terms of the
!  GNU General Public License: see COPYING in the top directory
!  or http://www.gnu.org/copyleft/gpl.txt .
! See Docs/Contributors.txt for a list of contributors.
! ---
      module m_siesta_analysis
      use write_subs

      private
      public :: siesta_analysis

      CONTAINS

      subroutine siesta_analysis( relaxd )
      USE band, only: nbk, bk, maxbk, bands
      USE writewave, only: nwk, wfk, wwave
      USE writewave, only: setup_wfs_list, wfs_filename
      USE m_ksvinit, only: nkpol, kpol, wgthpol
      use m_ksv
      USE m_projected_DOS, only: projected_DOS
      USE m_local_DOS, only: local_DOS
      USE siesta_options
      use units, only: Debye, eV
      use sparse_matrices, only: maxnh, listh, listhptr, numh
      use sparse_matrices, only: H, S, Dscf, Dold, Eold, xijo
      use siesta_geom
      use m_dhscf, only: dhscf
      use atomlist, only: indxuo, iaorb, lastkb, lasto, datm, no_l,
     &                    iphkb, no_u, no_s, iza, iphorb, rmaxo, indxua
      use fdf
      use writewave,    only: wwave
      use siesta_cml
      use files,        only : slabel
      use files,        only : filesOut_t   ! derived type for output file names
      use zmatrix,      only: lUseZmatrix, write_zmatrix
      use Kpoint_grid
      use parallel, only: IOnode
      use files,       only : label_length
      use m_energies
      use m_steps, only: final
      use m_ntm
      use m_spin,         only: nspin
      use m_dipol
      use m_eo
      use m_forces,          only: fa
      use m_gamma 
      use alloc,             only: re_alloc, de_alloc
      use basis_enthalpy,    only: write_basis_enthalpy
      use m_partial_charges, only: want_partial_charges
      use m_siesta2wannier90, only: siesta2wannier90
      use siesta_options,     only: w90_processing

      use m_mpi_utils, only: barrier

      implicit none

      logical :: relaxd, getPSI, quenched_MD

      real(dp)          :: dummy_str(3,3)
      real(dp)          :: dummy_strl(3,3)
      real(dp)          :: qspin(4)         ! Local

      real(dp)          :: polxyz(3,nspin)  ! Autom., small
      real(dp)          :: polR(3,nspin)    ! Autom., small
      real(dp)          :: qaux
      real(dp), pointer :: ebk(:,:,:)       ! Band energies

      integer           :: j, ix, ind, ik, io, ispin
      integer           :: wfs_band_min, wfs_band_max
      real(dp)          :: g2max
      type(filesOut_t)  :: filesOut  ! blank output file names

!-----------------------------------------------------------------------BEGIN

      ! Check that we are converged in geometry,
      ! if strictly required,
      ! before carrying out any analysis
      
      quenched_MD =  ( (iquench > 0) .and.
     $     ((idyn .eq. 1) .or. (idyn .eq. 3)) )

      if ((nmove .ne. 0) .or. quenched_MD) then
         if (GeometryMustConverge .and. (.not. relaxd)) then
            call message("FATAL",
     $           "GEOM_NOT_CONV: Geometry relaxation not converged")
            call timer('all',2)
            call timer('all',3)
            call barrier()
            call die("ABNORMAL_TERMINATION")
         endif
      endif

      call timer( 'siesta_analysis', 1 )
      
!     All the comments below assume that this compatibility option
!     is not used.
!     Note also that full compatibility cannot be guaranteed

      if (.not. compat_pre_v4_dynamics) then

!     This is a sanity safeguard: we reset the geometry (which might
!     have been moved by the relaxation or MD routines) to the one used
!     in the last computation of the electronic structure.
!     See the comments below for explanation

         xa(1:3,1:na_s) = xa_last(1:3,1:na_s)
         ucell(1:3,1:3) = ucell_last(1:3,1:3)
         scell(1:3,1:3) = scell_last(1:3,1:3)

      endif

      !** zmatrix info reset??

      final = .true.
      if (cml_p) then
        call cmlStartModule(xf=mainXML, title='Finalization')
      endif
!
!     NOTE that the geometry output by the following sections
!     used to be that "predicted" for the next MD or relaxation step.
!     This is now changed

!
      if (IOnode) then
        ! Print atomic coordinates

        ! This covers CG and MD-quench (verlet, pr), instances in which 
        ! "relaxd" is meaningful

        if ((nmove .ne. 0) .or. quenched_MD) then

          if (relaxd) then  ! xa = xa_last
             ! The "relaxation" routines do not update
             ! the coordinates if relaxed, so this behavior is unchanged
             call outcoor(ucell, xa, na_u, 'Relaxed', .true. )
          else  
             ! Since xa = xa_last now, this will just repeat the
             ! last set of coordinates used, not the predicted ones.
             call outcoor(ucell, xa, na_u, 'Final (unrelaxed)', .true. )
          endif

        endif

        ! This call will write xa_last to the .STRUCT_OUT file
        ! (again, since it has already been written by state_init),
        ! CML records of the latest processed structure, and 
        ! possibly zmatrix info.  *** unmoved?? how?
        ! Note that the .STRUCT_NEXT_ITER file is produced
        ! in siesta_move for checkpointing of relaxations and MD runs.

        ! If all we want are the CML records (to satisfy some expectation
        ! of appearance in the "finalization" section, we might put the
        ! cml call explicitly and forget about the rest.

        if (compat_pre_v4_dynamics) then
           call siesta_write_positions(moved=.true.)  
        else
           call siesta_write_positions(moved=.false.)  
        endif


        
        ! ??  Clarify Zmatrix behavior ****
        if (lUseZmatrix) call write_Zmatrix

        ! Print unit cell (cell_last) for variable cell and server operation
        if ( varcel .or. (idyn.eq.8)) call outcell(ucell)

!------------------------------------------------------------------
        ! It can be argued that these needed the xa_last coordinates
        ! all along

!       Print coordinates in xmol format in a separate file
        if (fdf_boolean('WriteCoorXmol',.false.)) 
     &     call coxmol(iza, xa, na_u )

!       Print coordinates in cerius format in a separate file
        if (fdf_boolean('WriteCoorCerius',.false.))
     &     call coceri(iza, xa, ucell, na_u, sname )

!       Find interatomic distances (output in file BONDS_FINAL)
        call bonds( ucell, na_u, isa, xa,
     &       rmax_bonds, trim(slabel) // ".BONDS_FINAL" )

      endif ! IONode
!--- end output of geometry information
!
!
! NOTE: In the following sections, wavefunction generation, computation
!       of band structure, etc, are carried out using the last Hamiltonian
!       generated in the SCF run for the last geometry considered.

!***   But, if xa /= xa_last, the computation of, say, bands, will use
!      H phases which are not the same as those producing the final 
!      ground-state electronic structure.
!
!**    Also, since we have removed the replication (superx call) 
!      of "moved" coordinates
!      into the auxiliary supercell from 'siesta_move' (recall that it is
!      done always in state_init for every new geometry), the "moved unit
!      cell coordinates" could coexist here with "unmoved non-unit cell SC coords",
!      which is wrong.

!**      For all of the above, we should put here a sanity safeguard
!        (if we have not done so already at the top of this routine)

!        xa(1:3,1:na_s) = xa_last(1:3,1:na_s)
!        ucell(1:3,1:3) = ucell_last(1:3,1:3)
!        scell(1:3,1:3) = scell_last(1:3,1:3)

!**        DM and H issues
!
!        Some of the routines that follow use H and S, and some use the DM.
!        Those which use the DM should work with the final "out" DM for
!        consistency.
!        Those which use H,S should work with the latest diagonalized H,S pair.
!
!**      If mixing the DM during the scf loop we should avoid mixing it one more time
!        after convergence (or restoring Dold)
!        If mixing H, we should avoid mixing it one more time
!        after convergence (and restoring Hold to have the exact H that generated the
!        latest DM, although this is probably too much).
!        See the logic in siesta_forces.

!     Find and print wavefunctions at selected k-points
!**   This uses H,S, and xa
      if (nwk.gt.0) then
        wfs_filename = trim(slabel)//".selected.WFSX"
        if (IONode) print "(a)",
     $              "Writing WFSX for selected k-points in "
     $                           // trim(wfs_filename)
        call wwave( no_s, nspin, nspin, no_u, no_l, maxnh, nwk,
     &              numh, listhptr, listh, H, S, Ef, xijo, indxuo,
     &              nwk, wfk, no_u, gamma, occtol )
      endif


!**   This uses H,S, and xa
      if (write_coop) then
        ! Output the wavefunctions for the kpoints in the SCF set
        ! Note that we allow both a band number and an energy range
        ! The user is responsible for using appropriate values.
        wfs_band_min = fdf_get("WFS.BandMin",1)
        wfs_band_max = fdf_get("WFS.BandMax",no_u)
        call setup_wfs_list(nkpnt,no_u,wfs_band_min,wfs_band_max,
     $                      use_scf_weights=.true.,
     $                      use_energy_window=.true.)
         wfs_filename = trim(slabel)//".fullBZ.WFSX"
         if (IONode) print "(a)", "Writing WFSX for COOP/COHP in " 
     $                           // trim(wfs_filename)
         call wwave( no_s, nspin, nspin, no_u, no_l, maxnh, maxk,
     .        numh, listhptr, listh, H, S, Ef, xijo, indxuo,
     .        nkpnt, kpoint, no_u, gamma, occtol)
      endif

!     Compute bands
!**   This uses H,S, and xa
      nullify( ebk )
      call re_alloc( ebk, 1, no_u, 1, nspin, 1, maxbk,
     &               'ebk', 'siesta_analysis' )

      if (nbk.gt.0) then
        if (IONode) print "(a)", "Computing bands..."
        getPSI = fdf_get('WFS.Write.For.Bands', .false.)
        if (getPSI) then
           wfs_filename = trim(slabel)//".bands.WFSX"
         if (IONode) print "(a)", "Writing WFSX for bands in "
     $                           // trim(wfs_filename)
           wfs_band_min = fdf_get("WFS.BandMin",1)
           wfs_band_max = fdf_get("WFS.BandMax",no_u)
           call setup_wfs_list(nbk,no_u,wfs_band_min,wfs_band_max,
     $          use_scf_weights=.false.,
     $          use_energy_window=.false.)
        endif
        call bands( no_s, nspin, nspin, no_u, no_l, maxnh, maxbk,
     .              numh, listhptr, listh, H, S, Ef, xijo, indxuo,
     .              .true., nbk, bk, ebk, occtol, getPSI )
        if (IOnode) then
          if ( writbk ) then
            write(6,'(/,a,/,a4,a12)')
     &       'siesta: Band k vectors (Bohr**-1):', 'ik', 'k'
            do ik = 1,nbk
              write(6,'(i4,3f12.6)') ik, (bk(ix,ik),ix=1,3)
            enddo
          endif
        
          if ( writb ) then
            write(6,'(/,a,/,a4,a3,a7)')
     &       'siesta: Band energies (eV):', 'ik', 'is', 'eps'
            do ispin = 1,min(nspin,2)
              do ik = 1,nbk
                write(6,'(i4,i3,10f7.2)')
     &            ik, ispin, (ebk(io,ispin,ik)/eV,io=1,min(10,no_u))
                if (no_u.gt.10) write(6,'(7x,10f7.2)')
     &              (ebk(io,ispin,ik)/eV,io=11,no_u)
              enddo
            enddo
          endif
        endif
      endif

!     Print eigenvalues
      if (IOnode .and. writeig) then
        if ((isolve.eq.SOLVE_DIAGON .or.
     &       ((isolve.eq.SOLVE_MINIM) .and. minim_calc_eigenvalues))
     &      .and. no_l.lt.1000) then
          if (nspin .le. 2) then
            write(6,'(/,a,/,a4,a3,a7)')
     &       'siesta: Eigenvalues (eV):', 'ik', 'is', 'eps'
            do ik = 1,nkpnt
              do ispin = 1,nspin
                write(6,'(i4,i3,10f7.2)')
     &            ik,ispin,(eo(io,ispin,ik)/eV,io=1,min(10,neigwanted))
                if (no_u.gt.10) write(6,'(7x,10f7.2)')
     &            (eo(io,ispin,ik)/eV,io=11,neigwanted)
              enddo
            enddo
          else
            write(6,'(/,a)') 'siesta: Eigenvalues (eV):'
            do ik = 1,nkpnt
              write(6,'(a,i6)') 'ik =', ik
              write(6,'(10f7.2)')
     &          ((eo(io,ispin,ik)/eV,io=1,neigwanted),ispin=1,2)
            enddo
          endif
          write(6,'(a,f15.6,a)') 'siesta: Fermi energy =', ef/eV, ' eV'
        endif
      endif

      if (((isolve.eq.SOLVE_DIAGON).or.
     &     ((isolve.eq.SOLVE_MINIM).and.minim_calc_eigenvalues))
     &    .and.IOnode)
     &     call ioeig(eo,ef,neigwanted,nspin,nkpnt,no_u,nspin,maxk,
     &                kpoint, kweight)


!**   This uses H,S, and xa, as it diagonalizes them again
      call projected_DOS()

!     Print program's energy decomposition and final forces
      if (IOnode) then
        call siesta_write_energies( first=.false., iscf=0, dDmax=0.0_dp)
        ! final == .true. which makes the step counter irrelevant
        call siesta_write_forces(-1)
        call siesta_write_stress_pressure()
        call write_basis_enthalpy(FreeE,FreeEHarris)
      endif

! NOTE: Here, the spin polarization is computed using Dscf, which is
!       a density matrix obtained after mixing the "in" and "out"
!       DMs of the SCF run for the last geometry considered.
!       This can be considered a feature or a bug.

      call print_spin(qspin)  ! qspin returned for use below

!**   This uses the last computed dipole in dhscf during the scf cycle,
!     which is in fact derived from the "in" DM.
!     Perhaps this section should be moved after the call to dhscf below
!     AND use the DM_out of the last step (but there might not be a call
!     to dhscf if there are no files to output, and the computation of the
!     charge density is expensive...

!     Print electric dipole
      if (shape .ne. 'bulk') then
        if (IOnode) then
          write(6,'(/,a,3f12.6)')
     &      'siesta: Electric dipole (a.u.)  =', dipol
          write(6,'(a,3f12.6)')
     &      'siesta: Electric dipole (Debye) =', 
     &      (dipol(ix)/Debye,ix=1,3)
        endif
        if (cml_p) then
          call cmlAddProperty(xf=mainXML, value=dipol/Debye,
     &         title='Electric dipole', dictref='siesta:dipol',
     .         units='siestaUnits:Debye')
        endif !cml_p
      endif

! NOTE: The use of *_last geometries in the following sections
!       guarantees that the analysis of the electronic structure
!       is done for the geometry for which it was computed.

!!  BUT these routines need H,S, so H should not be mixed after
!       convergence.

!     Calculation of the bulk polarization using the Berry phase
!     formulas by King-Smith and Vanderbilt
      if (nkpol.gt.0 .and. .not.bornz) then
        call KSV_pol(na_u, na_s, xa_last, rmaxo, scell_last, ucell_last,
     &               no_u, no_l, no_s, nspin, qspin, 
     &               maxnh, nkpol, numh, listhptr, listh, 
     &               H, S, xijo, indxuo, isa, iphorb, 
     &               iaorb, lasto, shape,
     &               nkpol,kpol,wgthpol, polR, polxyz ) 
      endif

!     Calculation of the optical conductivity
      call optical(na_u, na_s, xa_last, scell_last, ucell_last,
     &             no_u, no_l, no_s, nspin, qspin,
     &             maxnh, numh, listhptr, listh, H, S, xijo,
     $             indxuo, ebk, ef, temp,
     &             isa, iphorb, iphKB, lasto, lastkb, shape )

      call de_alloc( ebk, 'ebk', 'siesta_analysis' )
!...................................

!
!  NOTE: Dscf here might be the mixed one (see above).
!
      want_partial_charges = (hirshpop .or. voropop) .AND.
     $                   (.not. partial_charges_at_every_geometry)

!     Save electron density and potential
      if (saverho .or. savedrho .or. saverhoxc .or. 
     &    savevh .or. savevt .or. savevna .or.
     &    savepsch .or. savetoch .or. 
     &    want_partial_charges) then
        if (saverho)   filesOut%rho   = trim(slabel) // '.RHO'
        if (savedrho)  filesOut%drho  = trim(slabel) // '.DRHO'
        if (saverhoxc) filesOut%rhoxc = trim(slabel) // '.RHOXC'
        if (savevh)    filesOut%vh    = trim(slabel) // '.VH'
        if (savevt)    filesOut%vt    = trim(slabel) // '.VT'
        if (savevna)   filesOut%vna   = trim(slabel) // '.VNA'
        if (savepsch)  filesOut%psch  = trim(slabel) // '.IOCH'
        if (savetoch)  filesOut%toch  = trim(slabel) // '.TOCH'
        g2max = g2cut
        dummy_str  = 0.0
        dummy_strl = 0.0
        call dhscf( nspin, no_s, iaorb, iphorb, no_l,
     .              no_u, na_u, na_s, isa, xa_last, indxua, 
     &              ntm, 0, 0, 0, filesOut, 
     &              maxnh, numh, listhptr, listh, Dscf, Datm,
     &              maxnh, H, Enaatm, Enascf, Uatm, Uscf, DUscf, DUext,
     &              Exc, Dxc, dipol, dummy_str, fa, dummy_strl )
                    ! next to last argument is dummy here,
                    ! as no forces are calculated
                    ! todo: make all these optional
      endif
C    
C     Call the wannier90 interface here, as local_DOS destroys the DM...
C
      if( w90_processing) call siesta2wannier90()

C     Find local density of states
!  It needs H,S, and xa, as it diagonalizes them again
!  NOTE: This call will obliterate Dscf
!  It is better to put a explicit out argument for the partial DM computed.
      call local_DOS()

!*** In summary, it is better to:
!
!   -- Avoid (or warn the user about) doing any analysis if the calculation is not converged
!   -- Avoid mixing DM or H after scf convergence
!   -- Set xa to xa_last at the top of this file. Write any "next iter" coordinate file
!      in 'siesta_move'

      call timer( 'siesta_analysis', 2 )

!--------------------------------------------------------------------------- END
      END subroutine siesta_analysis
      END module m_siesta_analysis
