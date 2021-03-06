#' Trackit 2D
#' 
#' Function to track particles through a ROMS-field in 2D-space. 
#' 
#' Due to the limitation of RAM available, time is restricted depending on the number of particles
#' (too long runs might give an error because the generated vector is too large)
#' If sedimentation=TRUE, then particles stop in areas with low current speed. default is FALSE
#'
#' @param pts input points
#' @param kdtree kd tree
#' @param w_sink sinking rate in m/days
#' @param time total number of days to run the model
#' @param sedimentation defines stopping conditions for the particles. If TRUE, particles stop depending on their size and on the current speed and number of particles in a cell
#' @param particle_radius particle radius for the sedimentation, default is set to 0.16mm
#' @param force_final_settling This can be set to TRUE to force all floating particles at the end of the model-run to settle. This is useful because otherwise a stopindex for those points is not defined
#' @param romsparams parameters that are filled when this function is called from loopit 
#' @param uphill_restricted define whether particles are restricted from moving uphill, defined as from how many meters difference particles cannot cross between cells
#' @param sedimentationparams parameters estimated through the buildparams-function
#' @param mean_move to use when uphill_resticted is TRUE. Checks the final position of the particles and when usually they would be located back at their starting point for violating the uhill restriction, the code iterates to find a position in between that might still belong to the ROMS-cell the particle originates from
#'
#' @return list(ptrack = ptrack, pnow = pnow, plast = plast, stopindex = stopindex, indices = indices, indices_2D = indices_2D)
#' @export
#' @examples 
#' data(surface_chl)
#' data(toyROMS)
#' pts_seeded <- create_points_pattern(surface_chl, multi=100)
#' track <- trackit_2D(pts = pts_seeded, romsobject = toyROMS, force_final_settling=TRUE)
#' 
#' ## where points end up
#' plot(track$pnow, col="red", cex=0.1)
#' points(pts_seeded, cex=0.1)
#' 
#' ## where points stop
#' pend <- data.frame(matrix(NA, ncol=2, nrow=nrow(pts_seeded)))
#' for(irow in 1:nrow(pts_seeded)){
#'   pend[irow,] <- track$ptrack[irow,1:2,track$stopindex]
#' }
#' plot(pend, col="red", cex=0.6)
#' points(pts_seeded)
#' 
#' ## with stronger currents:
#' toyROMS2 <- toyROMS
#' toyROMS2$i_u <- toyROMS$i_u*5
#' toyROMS2$i_v <- toyROMS$i_v*5
#' track <- trackit_2D(pts = pts_seeded, romsobject = toyROMS2)
#' plot(pts_seeded)
#' points(track$pnow, col="red", cex=0.6)
#' 
#' 
#' 
#' 
#' 
#' 
#' 
#' ## looking at the results together with roms:
#' library(rasterVis)
#' library(rgdal)
#' library(rgl)
#' 
#' ra <- raster(nrow = 50, ncol = 50, ext = extent(surface_chl))
#' r_roms <- rasterize(x = cbind(as.vector(toyROMS$lon_u), as.vector(toyROMS$lat_u)), y = ra, field = as.vector(-toyROMS$h))
#' plot(r_roms)
#' 
#' ## what the floor-current-speed looks like
#' ra <- raster(nrow = 50, ncol = 50, ext = extent(surface_chl))
#' i_uv_roms <- rasterize(x = cbind(as.vector(toyROMS$lon_u), as.vector(toyROMS$lat_u)), y = ra, field = sqrt(as.vector(toyROMS$i_u)^2 + as.vector(toyROMS$i_v)^2))
#' plot(i_uv_roms)




trackit_2D <- function(pts, romsobject, w_sink=100, time=50, sedimentation=FALSE, particle_radius=0.00016, 
                       force_final_settling=FALSE, romsparams=NULL, sedimentationparams=NULL, loop_trackit=FALSE,
                       time_steps_in_s = 1800, uphill_restricted=NULL, sed_at_max_speed=FALSE, mean_move=FALSE){
  
  ## We need an id for each particle to be able to follow individual tracks
  id_vec <- seq_len(nrow(pts))

  ## build a kdtree
  if(loop_trackit==TRUE){
    kdtree <- romsobject$kdtree
    kdxy <- romsobject$kdxy
  }else{
    sknn <- with(romsobject, setup_knn(lon_u, lat_u, hh))             # (lon_roms=lon_u, lat_roms=lat_u, depth_roms=hh)
    kdtree <- sknn$kdtree
    kdxy <- sknn$kdxy
  }
  
  ## assign current speeds and depth for each ROMS-cell (lat/lon position)
  if(!is.null(romsparams)){
    i_u <- romsparams$i_u
    i_v <- romsparams$i_v
    i_w <- romsparams$i_w
    h <- romsparams$h
    roms_ext <- romsparams$roms_ext
  }else{
    i_u <- romsobject$i_u
    i_v <- romsobject$i_v
    i_w <- romsobject$i_w
    h <- romsobject$h
    roms_ext <- c(min(romsobject$lon_u), max(romsobject$lon_u), min(romsobject$lat_u), max(romsobject$lat_u))
  }

  ## w_sink is m/days, time is days
  w_sink <- -w_sink/(60*60*24)                               ## sinking speed transformation into m/sec
  ntime <- time*24*2                                         ## days transformation into 0.5h-intervals

  ## empty objects for the loop
  ptrack <- array(0, c(length(as.vector(pts))/3, 3, ntime))  ## create an empty array to store particle-tracks
  stopped <- rep(FALSE, length(as.vector(pts))/3)            ## create a stopping-vector
  stopindex <- rep(0, length(as.vector(pts))/3)              ## a vector to store indices of when particles stopped
  indices <- vector("list", ntime)                           ## a list of indices to store which 3D-cell a particle is in
  indices_2D <- vector("list", ntime)                        ## a list of indices to store which 2D-cell a particle is in                       

  pnow <- plast <- pts                ## copies of the starting points for updating in the loop
  
  ## different to 3D this line
  if(!is.null(sedimentationparams)){params <- sedimentationparams 
  }else params <- buildparams(w_sink, time_step_in_s = time_steps_in_s, r=particle_radius)
  
  for (itime in seq_len(ntime)) {
    
    if(loop_trackit==FALSE){
      if(itime==1) message(paste0("starting # of particles: ",dim(pts)[1]))
      print(itime)
    }

    ## different to trackit_3D in these two lines: find depth for each pnow
    ## this is not neccessary as the 3D-kdtree already picks the correct cells... why?
    ## I think 1 is the deepest layer, so if you wanted to track particles 2D in another layer, 
    ## this would need to be adressed somewhere here
    #depth_pos <- kdxy$query(pnow[,1:2], k = 1, eps = 0)
    #pnow[,3] <- h[depth_pos$nn.idx]
    
    ## index 1st nearest neighbour of trace points to grid points
    dmap <- kdtree$query(plast, k = 1, eps = 0)           ## one kdtree
    ## and to 2D space
    two_dim_pos <- kdxy$query(plast[,1:2], k = 1, eps = 0)
    
    ## store indices for tracing particle positions
    indices[[itime]] <- dmap$nn.idx
    indices_2D[[itime]] <- two_dim_pos$nn.idx
    
    ## different to 3D in this line: (two_dim_pos returns the cell-index of each point, (find the nearest grid-point from lon_u/lat_u and return its index))
    idx_for_roms <- two_dim_pos$nn.idx
    #displacement <- dmap$nn.idx

    ## extract component values from the vars
    thisu <- i_u[idx_for_roms]                             ## u-component of ROMS
    thisv <- i_v[idx_for_roms]                             ## v-component of ROMS
    #thisw <- i_w[idx_for_roms]                            ## w-component of ROMS
    thish <- h[idx_for_roms]                               ## depth of ROMS-cell
    
    ## update this time step longitude, latitude, depth
    pnow[,1] <- plast[,1] + (thisu * time_steps_in_s) / (1.852 * 60 * 1000 * cos(plast[,2] * pi/180))
    pnow[,2] <- plast[,2] + (thisv * time_steps_in_s) / (1.852 * 60 * 1000)
    ## different to 3D this line
    #pnow[,3] <- pmin(0, plast[,3])  + ((thisw + w_sink)* time_steps_in_s )
    
    ##########---- only in trackit_2D:
    tdp_idx <- kdxy$query(pnow[,1:2], k = 1, eps = 0)$nn.idx
    ## make sure particles are not travelling upwards to cells more than 30m higher
    #if (depth of pnow) < (depth of plast) then assign plast to pnow with no displacement
    if(!is.null(uphill_restricted)){
      uphill <- h[tdp_idx] < thish - uphill_restricted
      if(mean_move==FALSE){
        pnow[uphill==TRUE,] <- plast[uphill==TRUE,]
      }else if(mean_move==TRUE){
        ## take the mean position between the location and test in which cell it is
        pnow[uphill==TRUE,] <- apply(simplify2array(list(pnow[uphill==TRUE,],plast[uphill==TRUE,])), 1:2, mean)
        test.tdp_idx <- kdxy$query(pnow[,1:2], k = 1, eps = 0)$nn.idx
        still.uphill <- h[test.tdp_idx] < thish - uphill_restricted
        
        ## repeat procedure
        pnow[still.uphill==TRUE,] <- apply(simplify2array(list(pnow[still.uphill==TRUE,],plast[still.uphill==TRUE,])), 1:2, mean)
        test2.tdp_idx <- kdxy$query(pnow[,1:2], k = 1, eps = 0)$nn.idx
        stillstill.uphill <- h[test2.tdp_idx] < thish - uphill_restricted
        
        ## all pts that are really close to the border come back to original position
        pnow[stillstill.uphill==TRUE,] <- plast[stillstill.uphill==TRUE,]
      }
    }
    
    ## stopping conditions (when outside the limits of the area) 
    stopped <- (pnow[,1] < roms_ext[1] | pnow[,1] > roms_ext[2] |
                  pnow[,2] < roms_ext[3] | pnow[,2] > roms_ext[4]
    )
    ## stopping conditions-2 (calculate stopping particles given a sedimentation process):
    if(sedimentation){
      ## how many particles are there for each cell-index    which(tabulate(k)!=0) selects the same cells as table(k), but keeps their index
      all_dens <- tabulate(tdp_idx)
      
      ## speed and density for each cell:
      l <- unique(tdp_idx)  #indices of each "used" cell
      #speed in active cells, needs to be in squared for equation
      if(sed_at_max_speed==FALSE){cell_chars <- data.frame(cbind(l, i_u[l] ^ 2 + i_v[l] ^ 2))
      }else cell_chars <- data.frame(cbind(l, romsparams$i_u_max[l] ^ 2 + romsparams$i_v_max[l] ^ 2))
      #point-density in active cells
      cell_chars[,3] <- all_dens[l]
      #get u_div from observed and critical velocity 
      U_div <- 1-(cell_chars[,2] / params$Ucsq)
       ##no erosion:    
      U_div[U_div<0] <-0
      ## calculate number of points to settle for each cell (equation from McCave & Swift)
      cell_chars[,4] <- params$SedFunct(U_div, cell_chars[,3])

      #colnames(cell_chars) <- c("cell_index","velocity","n_pts_in_cell","n_pts_to_drop")
      
      ## forced settling out of the suspension:                      
      ## create an object to store points to be dropped
      #drop_pts <- rep(F,length(pnow)/2)                     

      ## qd: the quick and dirty solution to find which particles stop
      point_chars <- data.frame(cbind(tdp_idx, cell_chars[match(tdp_idx, cell_chars[,1]),3:4]))
      point_chars[,4] <- -(point_chars[,3] / point_chars[,2])
      t_f <- runif(nrow(point_chars)) <= point_chars[,4]

      stopindex[(stopindex == 0 & stopped) | (stopindex == 0 & t_f)] <- itime
    }else{
      stopindex[(stopindex == 0 & stopped)] <- itime
    }
    ##########----
  
    ## assign stopping location of points to ptrack 
    ptrack[,,itime] <- pnow
    plast <- pnow
    if (all(stopindex!=0)) {
      message("exiting, all stopped")
      break 
    }
  }
  ptrack <- ptrack[,,seq(itime),drop=FALSE]
  if(force_final_settling){
    stopindex[stopindex==0] <- itime
  }
  list(ptrack = ptrack, pnow = pnow, plast = plast, stopindex = stopindex, indices = indices, indices_2D = indices_2D)
}


####################################
## for the settlingmodel?

## This function is called in the function loopit
## the function needs an input for speed of the sinking particles (vertical_movement), the time of the run and the resolution of the run (time_step)
## due to the limitation of RAM available, time is restricted depending on the number of particles
## (too long runs might give an error because the generated vector is too large)

## u, v and w components need to be defined (i_u, i_v, i_w)

## give some room to define stopping conditions

# trackit <- function(vertical_movement,time,time_step){ ## vertical_movement is m/s, time is s, steps is in s
#   ptrack <- array(0, c(length(as.vector(pts))/3, 3, time))  ## create an empty array to store particle-tracks
#   stopped <- rep(FALSE, length(as.vector(pts))/3)            ## create a stopping-vector
#   stopindex <- rep(0, length(as.vector(pts))/3)              ## a vector to store indices of when particles stopped
#   plast <- pts                                               ## copies of the starting points for updating in the loop
#   pnow <- plast
#   #plot(pts, pch = ".")                                      ## to plot particles after each timestep
#   for (itime in seq_len(time)) {
#     ## index 1st nearest neighbour of trace points to grid points
#     dmap <- kdtree$query(plast, k = 1, eps = 0)           ## one kdtree from script "..._readit.R"
#     ## extract component values from the vars
#     thisu <- i_u[dmap$nn.idx]                             ## u-component of ROMS
#     thisv <- i_v[dmap$nn.idx]                             ## v-component of ROMS
#     thisw <- i_w[dmap$nn.idx]                             ## w-component of ROMS
#
#     ## update this time step longitude, latitude, depth
#     pnow[,1] <- plast[,1] + (thisu * time_step) / (1.852 * 60 * 1000 * cos(pnow[,2] * pi/180))
#     pnow[,2] <- plast[,2] + (thisv * time_step) / (1.852 * 60 * 1000)
#     pnow[,3] <- pmin(0, plast[,3])  + ((thisw + vertical_movement)* time_step )
#
#     ## hit the bottom
#     stopped <- pnow[,3] <= -h[kdxy$query(pnow[,1:2], k = 1, eps = 0)$nn.idx]
#     stopindex[stopindex == 0 & stopped] <- itime
#     ptrack[,,itime] <- pnow
#     plast <- pnow
#     print(itime)
#     if (all(stopped)) {
#       message("exiting, all stopped")
#       break;
#     }
#   }
#   ptrack <- ptrack[,,seq(itime)]
#   list(ptrack = ptrack, pnow = pnow, plast = plast, stopindex = stopindex)
# }
#
