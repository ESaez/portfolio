import React from 'react';
import Box from '@mui/material/Box';
import Typography from '@mui/material/Typography';
import Button from '@mui/material/Button';
import landingImage from '../assets/images/landing.jpeg'; // Adjust the path as needed

function Landing() {
	return (
		<Box
			sx={{
				height: '100vh',
				width: '100vw',
				display: 'flex',
				flexDirection: 'column',
				justifyContent: 'center',
				alignItems: 'center',
				padding: '20px',
				boxSizing: 'border-box',
				backgroundImage: `url(${landingImage})`,
				backgroundSize: 'cover', // 'cover' for all screen sizes
				backgroundPosition: 'center',
				backgroundRepeat: 'no-repeat',
				'@media (max-width:600px)': {
					// Custom styles for very small screens if necessary
					backgroundSize: 'cover',
					height: '50vh',
				},
			}}
		>
			<Typography
				variant="h3"
				sx={{ color: '#fbfbfb', fontWeight: 'bold', mb: 4, marginTop: '300px' }}
			>
				Welcome to My Portfolio
			</Typography>
			<Typography variant="h5" sx={{ color: '#fec86a', mb: 3 }}>
				Discover My Projects & Experience
			</Typography>
			<Button
				variant="contained"
				sx={{ backgroundColor: '#fec86a', color: '#34353b' }}
			>
				Learn More
			</Button>
		</Box>
	);
}

export default Landing;
